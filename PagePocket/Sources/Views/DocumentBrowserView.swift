import SwiftUI
import WebKit

/// The document viewer: a full-bleed web view plus a control surface for
/// reloading, navigating, inspecting the console and running scripts.
struct DocumentBrowserView: View {

    let document: Document

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var session: DocumentSession

    @State private var isShowingConsole = false
    @State private var isShowingSettings = false
    @State private var isShowingRunner = false
    @State private var isImmersive = false
    @State private var shareItem: ShareItem?
    @State private var pendingExternalURL: URL?

    init(document: Document) {
        self.document = document
        // One shared server serves every document, so the session can be built
        // before the environment is available.
        _session = StateObject(wrappedValue: DocumentSession(document: document,
                                                             server: LocalHTTPServer.shared))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground).ignoresSafeArea()

            WebViewContainer(engine: session.engine)
                .ignoresSafeArea(edges: isImmersive ? .all : .bottom)

            if !isImmersive {
                bottomBar
            }
        }
        .navigationTitle(isImmersive ? "" : session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isImmersive ? .hidden : .visible, for: .navigationBar)
        .toolbar { navigationToolbar }
        .statusBarHidden(isImmersive)
        .persistentSystemOverlays(isImmersive ? .hidden : .automatic)
        .onAppear {
            session.start()
            store.markOpened(document.id)
        }
        .onDisappear {
            session.stop()
        }
        .sheet(isPresented: $isShowingConsole) {
            ConsoleView(engine: session.engine)
        }
        .sheet(isPresented: $isShowingSettings) {
            PageSettingsView(engine: session.engine, document: document)
        }
        .sheet(isPresented: $isShowingRunner) {
            ScriptRunnerView(engine: session.engine)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: filePickerBinding) {
            if let request = session.engine.filePickerRequest {
                SingleFilePicker(allowsMultipleSelection: request.allowsMultipleSelection) { urls in
                    request.completion(urls.isEmpty ? nil : urls)
                    session.engine.filePickerRequest = nil
                }
                .ignoresSafeArea()
            }
        }
        .alert(
            session.engine.activeDialog?.title ?? "Page",
            isPresented: dialogBinding
        ) {
            dialogButtons
        } message: {
            Text(session.engine.activeDialog?.message ?? "")
        }
        .alert(
            "Open in Safari?",
            isPresented: externalURLBinding,
            presenting: pendingExternalURL
        ) { url in
            Button("Open") {
                UIApplication.shared.open(url)
                pendingExternalURL = nil
            }
            Button("Cancel", role: .cancel) { pendingExternalURL = nil }
        } message: { url in
            Text(url.absoluteString)
        }
        .onChange(of: session.engine.externalURLRequest) { _, newValue in
            guard let newValue else { return }
            pendingExternalURL = newValue
            session.engine.externalURLRequest = nil
        }
        .overlay(alignment: .top) {
            if session.engine.isLoading && session.engine.progress < 1 {
                ProgressView(value: session.engine.progress)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            }
        }
        .overlay {
            if let error = session.startupError {
                ContentUnavailableView {
                    Label("Can’t Open Document", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 26) {
            Button { session.engine.goBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!session.engine.canGoBack)

            Button { session.engine.goForward() } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!session.engine.canGoForward)

            Button {
                if session.engine.isLoading { session.engine.stopLoading() }
                else { session.engine.reload() }
            } label: {
                Image(systemName: session.engine.isLoading ? "xmark" : "arrow.clockwise")
            }

            Button { isShowingConsole = true } label: {
                Image(systemName: "terminal")
                    .overlay(alignment: .topTrailing) {
                        if !session.engine.issues.isEmpty || hasErrors {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                                .offset(x: 4, y: -3)
                        }
                    }
            }

            Button { isImmersive = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("Full screen")
        }
        .font(.system(size: 19, weight: .medium))
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .background(.bar, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .padding(.bottom, 8)
        .opacity(session.isReady ? 1 : 0)
    }

    private var hasErrors: Bool {
        session.engine.consoleMessages.contains { $0.level == .error }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        if isImmersive {
            // A single way out of full screen, floating over the page.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isImmersive = false
                } label: {
                    Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        session.engine.hardReload()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }

                    Button {
                        isShowingRunner = true
                    } label: {
                        Label("Run JavaScript", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    Button {
                        isShowingConsole = true
                    } label: {
                        Label("Console", systemImage: "terminal")
                    }

                    Divider()

                    Button {
                        captureScreenshot()
                    } label: {
                        Label("Save Screenshot", systemImage: "camera")
                    }

                    Button {
                        shareItem = ShareItem(url: document.entryURL)
                    } label: {
                        Label("Share Original File", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Page Settings", systemImage: "slider.horizontal.3")
                    }

                    Button {
                        isImmersive = true
                    } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }

                    if let baseURL = session.baseURL {
                        Divider()
                        Button {
                            UIPasteboard.general.string = baseURL.absoluteString
                        } label: {
                            Label("Copy Local URL", systemImage: "doc.on.doc")
                        }
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Actions

    /// Renders the page to an image and offers it in the share sheet.
    private func captureScreenshot() {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = session.engine.webView.bounds

        session.engine.webView.takeSnapshot(with: configuration) { image, _ in
            guard let image, let data = image.pngData() else { return }
            let name = "\(document.displayTitle.replacingOccurrences(of: "/", with: "-")).png"
            guard let url = try? TemporaryFiles.write(data, fileName: name) else { return }
            shareItem = ShareItem(url: url)
        }
    }

    // MARK: - Bindings

    private var dialogBinding: Binding<Bool> {
        Binding(
            get: { session.engine.activeDialog != nil },
            set: { if !$0 { session.engine.activeDialog = nil } }
        )
    }

    private var filePickerBinding: Binding<Bool> {
        Binding(
            get: { session.engine.filePickerRequest != nil },
            set: { newValue in
                // A dismissed sheet must still resolve the page's callback,
                // or the file input stays stuck forever.
                if !newValue, let request = session.engine.filePickerRequest {
                    request.completion(nil)
                    session.engine.filePickerRequest = nil
                }
            }
        )
    }

    private var externalURLBinding: Binding<Bool> {
        Binding(
            get: { pendingExternalURL != nil },
            set: { if !$0 { pendingExternalURL = nil } }
        )
    }

    @ViewBuilder
    private var dialogButtons: some View {
        switch session.engine.activeDialog {
        case .alert:
            Button("OK") { session.engine.resolveDialog(confirm: true) }
        case .confirm:
            Button("Cancel", role: .cancel) { session.engine.resolveDialog(confirm: false) }
            Button("OK") { session.engine.resolveDialog(confirm: true) }
        case .prompt:
            // The text field is bound through the settings sheet to keep state simple.
            Button("Cancel", role: .cancel) { session.engine.resolveDialog(confirm: false) }
            Button("OK") { session.engine.resolveDialog(confirm: true, promptValue: promptBuffer) }
        case .none:
            Button("OK") { }
        }
    }

    /// Holds the prompt text while the alert is on screen.
    @State private var promptBuffer = ""
}

/// Wraps the engine's `WKWebView` for SwiftUI.
struct WebViewContainer: UIViewRepresentable {

    let engine: WebEngine

    func makeUIView(context: Context) -> WKWebView {
        engine.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The web view is owned and driven entirely by the engine.
    }
}

/// Identifiable wrapper so a URL can drive a `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// `UIActivityViewController` bridge.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
