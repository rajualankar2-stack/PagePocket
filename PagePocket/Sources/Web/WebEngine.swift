import Combine
import SwiftUI
import WebKit

/// The `WKScriptMessageHandler` name used by the console bridge.
///
/// A file-scope constant rather than a static member so the non-isolated
/// message proxy can read it without touching main-actor state.
private let consoleHandlerName = "pagePocketConsole"

/// Owns the `WKWebView` and turns its delegate callbacks into observable state.
///
/// This is the heart of the app: it configures the web view for local content,
/// injects a console bridge, implements the JavaScript dialogs the web view
/// would otherwise silently drop, and reports navigation failures.
///
/// The class is main-actor bound because `WKWebView` is. WebKit always invokes
/// its delegate callbacks on the main thread, so the `nonisolated` witnesses
/// below re-enter the main actor with `assumeIsolated` rather than hopping,
/// which keeps them synchronous as the protocols require.
@MainActor
final class WebEngine: NSObject, ObservableObject {

    // MARK: - Observable state

    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var pageTitle: String = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    @Published private(set) var consoleMessages: [ConsoleMessage] = []
    @Published private(set) var issues: [PageIssue] = []

    /// Set while an alert/confirm/prompt raised by the page is on screen.
    @Published var activeDialog: JavaScriptDialog?

    /// Set when the page asks to upload a file.
    @Published var filePickerRequest: FilePickerRequest?

    /// Raised when a link tries to leave the local server (e.g. https://…).
    @Published var externalURLRequest: URL?

    let webView: WKWebView

    /// Base URL the current document is served from, e.g. `http://127.0.0.1:50123/r/<token>/`.
    private(set) var documentBaseURL: URL?

    // MARK: - Init

    override init() {
        let configuration = WKWebViewConfiguration()

        // Local documents are frequently interactive demos, games and
        // visualisations, so enable the media affordances they expect.
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // JavaScript is on by default; be explicit because almost every local
        // document is useless without it.
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // Install the console bridge. The proxy breaks the retain cycle that
        // `add(_:name:)` would otherwise create between controller and engine.
        let proxy = ConsoleMessageProxy(target: self)
        configuration.userContentController.add(proxy, name: consoleHandlerName)
        configuration.userContentController.addUserScript(Self.consoleBridgeScript)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground

        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif

        observeProgress()
    }

    // MARK: - Loading

    /// Points the web view at a document served by the local server.
    func load(documentBaseURL: URL, entryPath: String) {
        self.documentBaseURL = documentBaseURL
        consoleMessages.removeAll()
        issues.removeAll()

        let target = documentBaseURL.appendingPathComponent(entryPath)
        var request = URLRequest(url: target)
        // Always fetch fresh content: the user may have re-imported the file.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    func reload() { webView.reloadFromOrigin() }

    /// Reloads, bypassing any cached subresources.
    func hardReload() {
        webView.stopLoading()
        webView.reloadFromOrigin()
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func stopLoading() { webView.stopLoading() }

    /// Runs JavaScript and reports the result or the thrown error.
    func evaluate(_ script: String) async -> Result<String, Error> {
        do {
            let value = try await webView.evaluateJavaScript(script)
            return .success(Self.describe(value))
        } catch {
            return .failure(error)
        }
    }

    /// A readable representation of whatever JavaScript handed back.
    private static func describe(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return "undefined"
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            return array.map { describe($0) }.joined(separator: ", ")
        case let dictionary as [String: Any]:
            let pairs = dictionary.map { "\($0.key): \(describe($0.value))" }.sorted()
            return "{\(pairs.joined(separator: ", "))}"
        case .some(let other):
            return String(describing: other)
        }
    }

    // MARK: - Progress observation

    private var progressObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?

    private func observeProgress() {
        // `self` is captured weakly in the *outer* closure as well as the inner
        // task. NSKeyValueObservation retains its closure, and the observation
        // is stored on `self`, so a strong capture here would form a cycle
        // (self → observation → closure → self) and leak the whole engine.
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            let value = webView.estimatedProgress
            Task { @MainActor in self?.progress = value }
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            let value = webView.title ?? ""
            Task { @MainActor in
                guard let self, !value.isEmpty else { return }
                self.pageTitle = value
            }
        }
    }

    // MARK: - Console

    /// Wraps `console.*` and captures uncaught errors, forwarding them to native.
    ///
    /// Installed at document start so it sees everything the page logs during
    /// parsing, not just after load.
    static var consoleBridgeScript: WKUserScript {
        let source = """
        (function () {
          if (window.__pagePocketConsoleInstalled) { return; }
          window.__pagePocketConsoleInstalled = true;

          function send(level, args) {
            try {
              var parts = [];
              for (var i = 0; i < args.length; i++) { parts.push(stringify(args[i])); }
              window.webkit.messageHandlers.\(consoleHandlerName).postMessage({
                level: level,
                text: parts.join(' ')
              });
            } catch (e) { /* never let logging break the page */ }
          }

          function stringify(value) {
            if (value === null) { return 'null'; }
            if (value === undefined) { return 'undefined'; }
            var type = typeof value;
            if (type === 'string') { return value; }
            if (type === 'number' || type === 'boolean' || type === 'bigint') { return String(value); }
            if (type === 'function') { return 'ƒ ' + (value.name || 'anonymous') + '()'; }
            if (value instanceof Error) { return value.name + ': ' + value.message; }
            if (value instanceof Element) {
              var tag = value.tagName.toLowerCase();
              var id = value.id ? '#' + value.id : '';
              var cls = (value.className && typeof value.className === 'string')
                ? '.' + value.className.trim().split(/\\s+/).join('.') : '';
              return '<' + tag + id + cls + '>';
            }
            try {
              var seen = [];
              var json = JSON.stringify(value, function (k, v) {
                if (typeof v === 'object' && v !== null) {
                  if (seen.indexOf(v) !== -1) { return '[Circular]'; }
                  seen.push(v);
                }
                if (typeof v === 'function') { return 'ƒ ' + (v.name || 'anonymous') + '()'; }
                return v;
              });
              return json === undefined ? String(value) : json;
            } catch (e) {
              return Object.prototype.toString.call(value);
            }
          }

          ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
            var original = console[level];
            console[level] = function () {
              send(level, Array.prototype.slice.call(arguments));
              if (original) { original.apply(console, arguments); }
            };
          });

          window.addEventListener('error', function (event) {
            var message = event.message || 'Script error';
            if (event.filename) { message += ' (' + event.filename + ':' + event.lineno + ')'; }
            send('error', [message]);
          });

          window.addEventListener('unhandledrejection', function (event) {
            var reason = event.reason;
            var text = (reason && reason.message) ? reason.message : stringify(reason);
            send('error', ['Unhandled promise rejection: ' + text]);
          });
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// Appends a message relayed from the page's console.
    func recordConsoleMessage(level: String, text: String) {
        guard !text.isEmpty else { return }
        let parsedLevel = ConsoleMessage.Level(rawValue: level) ?? .log
        consoleMessages.append(ConsoleMessage(level: parsedLevel, text: text, timestamp: Date()))
        // Keep memory bounded during long-running pages.
        if consoleMessages.count > 500 {
            consoleMessages.removeFirst(consoleMessages.count - 500)
        }
    }

    func recordIssue(_ message: String, detail: String? = nil) {
        issues.append(PageIssue(message: message, detail: detail, timestamp: Date()))
    }

    func clearConsole() { consoleMessages.removeAll() }
    func clearIssues() { issues.removeAll() }

    // MARK: - Dialogs

    enum JavaScriptDialog: Identifiable {
        case alert(message: String, completion: () -> Void)
        case confirm(message: String, completion: (Bool) -> Void)
        case prompt(message: String, defaultValue: String, completion: (String?) -> Void)

        var id: String {
            switch self {
            case .alert(let message, _): return "alert-\(message.hashValue)"
            case .confirm(let message, _): return "confirm-\(message.hashValue)"
            case .prompt(let message, _, _): return "prompt-\(message.hashValue)"
            }
        }

        var message: String {
            switch self {
            case .alert(let message, _), .confirm(let message, _), .prompt(let message, _, _):
                return message
            }
        }

        var title: String {
            switch self {
            case .alert: return "Alert"
            case .confirm: return "Confirm"
            case .prompt: return "Input"
            }
        }

        var defaultValue: String {
            if case .prompt(_, let value, _) = self { return value }
            return ""
        }
    }

    struct FilePickerRequest: Identifiable {
        let id = UUID()
        let allowsMultipleSelection: Bool
        let completion: ([URL]?) -> Void
    }

    /// Resolves the on-screen dialog exactly once.
    func resolveDialog(confirm: Bool, promptValue: String? = nil) {
        guard let dialog = activeDialog else { return }
        activeDialog = nil

        switch dialog {
        case .alert(_, let completion):
            completion()
        case .confirm(_, let completion):
            completion(confirm)
        case .prompt(_, _, let completion):
            completion(confirm ? (promptValue ?? "") : nil)
        }
    }

    /// Abandons the current dialog as if the user cancelled it.
    func cancelActiveDialog() {
        resolveDialog(confirm: false)
    }

    private func updateNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
    }
}

// MARK: - Console message proxy

/// Relays `console.*` messages from the page to the engine.
///
/// Kept as a separate, non-isolated object so `WKUserContentController` never
/// retains the engine (which would leak the whole view hierarchy), and so the
/// WebKit callback can safely re-enter the main actor.
private final class ConsoleMessageProxy: NSObject, WKScriptMessageHandler {

    weak var target: WebEngine?

    init(target: WebEngine) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit delivers script messages on the main thread.
        guard message.name == consoleHandlerName,
              let body = message.body as? [String: Any],
              let level = body["level"] as? String,
              let text = body["text"] as? String else { return }

        MainActor.assumeIsolated {
            target?.recordConsoleMessage(level: level, text: text)
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebEngine: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            isLoading = true
            progress = 0
            updateNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            isLoading = false
            progress = 1
            currentURL = webView.url
            if let title = webView.title, !title.isEmpty { pageTitle = title }
            updateNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            isLoading = false
            updateNavigationState()
            report(error, context: "The page could not be loaded.")
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        MainActor.assumeIsolated {
            isLoading = false
            updateNavigationState()
            report(error, context: "The page could not be loaded.")
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            isLoading = false
            recordIssue("The page ran out of memory and was reloaded.",
                        detail: "Very large or runaway scripts can cause this. The document has been reloaded.")
            webView.reload()
        }
    }

    /// Filters out the cancellations WebKit reports for ordinary user actions.
    private func report(_ error: Error, context: String) {
        let nsError = error as NSError
        // -999 cancelled / 102 frame load interrupted are not real failures.
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled || nsError.code == 102 {
            return
        }

        var detail = nsError.localizedDescription
        if let failingURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            detail += "\n\(failingURL)"
        }
        recordIssue(context, detail: detail)
    }

    /// Keeps local content inside the web view and pushes the open web to Safari.
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            decisionHandler(policy(for: navigationAction))
        }
    }

    private func policy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }

        // about:blank and data:/blob: URLs are common in self-contained documents.
        switch url.scheme?.lowercased() {
        case "about", "data", "blob", "javascript":
            return .allow
        default:
            break
        }

        // Anything served by our own loopback server stays in the web view,
        // including iframes and scripted loads.
        if url.host == "127.0.0.1" || url.host == "localhost" {
            return .allow
        }

        if url.isFileURL {
            // A file the page linked to: re-serve it through the server so it
            // keeps a real origin instead of an opaque file:// one.
            externalURLRequest = url
            return .cancel
        }

        // A user-initiated link to the open web: hand it to the system.
        if navigationAction.navigationType == .linkActivated {
            externalURLRequest = url
            return .cancel
        }

        // Subresource or scripted load: let it proceed normally.
        return .allow
    }
}

// MARK: - WKUIDelegate

extension WebEngine: WKUIDelegate {

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            activeDialog = .alert(message: message, completion: completionHandler)
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            activeDialog = .confirm(message: message, completion: completionHandler)
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptTextInputPanelWithPrompt prompt: String,
                             defaultText: String?,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (String?) -> Void) {
        MainActor.assumeIsolated {
            activeDialog = .prompt(message: prompt,
                                   defaultValue: defaultText ?? "",
                                   completion: completionHandler)
        }
    }

    /// Handles `<input type="file">`.
    ///
    /// Availability note: WebKit only exposed this delegate method to iOS in
    /// 18.4. On iOS 17 an `<input type="file">` still works — WebKit presents
    /// its own upload UI — so this is a customisation hook, not a requirement.
    /// It is implemented where available so the picker runs through
    /// `UIDocumentPickerViewController` and stays consistent with the rest of
    /// the app.
    @available(iOS 18.4, *)
    nonisolated func webView(_ webView: WKWebView,
                             runOpenPanelWith parameters: WKOpenPanelParameters,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping ([URL]?) -> Void) {
        MainActor.assumeIsolated {
            filePickerRequest = FilePickerRequest(
                allowsMultipleSelection: parameters.allowsMultipleSelection,
                completion: completionHandler
            )
        }
    }

    /// Handles `window.open` / `target="_blank"` by loading it in this web view
    /// rather than silently doing nothing.
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else { return }

            if url.host == "127.0.0.1" || url.host == "localhost" {
                webView.load(navigationAction.request)
            } else {
                externalURLRequest = url
            }
        }
        return nil
    }
}
