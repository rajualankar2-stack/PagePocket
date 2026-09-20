import Social
import UniformTypeIdentifiers
import UIKit

/// Receives HTML files (and ZIP bundles) shared from the Files app, Safari, Mail
/// or any other app, and stages them for PagePocket to import.
///
/// The extension does **not** try to render anything itself. Extensions have a
/// tight memory budget and no reliable way to hand work to the host app, so the
/// job here is simply: copy the shared item into the shared App Group container,
/// then let the app pick it up. That keeps the actual viewer logic in one place.
final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        Task { await handleSharedItems() }
    }

    // MARK: - UI

    private func configureUI() {
        view.backgroundColor = .systemBackground

        statusLabel.text = "Importing…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let subtitle = UILabel()
        subtitle.text = "Adding to PagePocket"
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func showResult(_ message: String) {
        spinner.stopAnimating()
        statusLabel.text = message
    }

    // MARK: - Handling

    private func handleSharedItems() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish(with: "Nothing was shared.")
            return
        }

        let providers = items
            .compactMap { $0.attachments }
            .flatMap { $0 }

        guard !providers.isEmpty else {
            finish(with: "Nothing was shared.")
            return
        }

        var stagedCount = 0
        var skipped: [String] = []

        for provider in providers {
            do {
                if try await stage(provider) {
                    stagedCount += 1
                } else {
                    skipped.append(name(of: provider))
                }
            } catch {
                skipped.append(name(of: provider))
            }
        }

        if stagedCount > 0 {
            // Give the user a beat to read the confirmation before dismissing.
            showResult(stagedCount == 1 ? "Added to PagePocket" : "Added \(stagedCount) items")
            try? await Task.sleep(nanoseconds: 900_000_000)
            finish(with: nil)
        } else if skipped.isEmpty {
            finish(with: "Nothing was shared.")
        } else {
            finish(with: "PagePocket can’t open that file type.")
        }
    }

    /// Copies one item into the shared inbox. Returns `false` if the type is not supported.
    private func stage(_ provider: NSItemProvider) async throws -> Bool {
        // A folder arrives as a file URL too, so the URL path covers both.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let url = try await loadFileURL(from: provider) else { return false }
            // `.zip` bundles are accepted alongside HTML.
            let ext = url.pathExtension.lowercased()
            let supported = ["html", "htm", "xhtml", "zip", "svg"]
            guard supported.contains(ext) else { return false }

            try SharedInbox.stage(at: url)
            return true
        }

        // Some sources hand over raw HTML data rather than a file.
        if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
            let data = try await loadData(from: provider, typeIdentifier: UTType.html.identifier)
            guard let data, !data.isEmpty else { return false }

            let inbox = try SharedInbox.ensureInbox()
            let destination = inbox.appendingPathComponent("Shared Page \(Int(Date().timeIntervalSince1970)).html")
            try data.write(to: destination, options: .atomic)
            return true
        }

        // Plain text that is actually markup (e.g. copied from an editor).
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let data = try await loadData(from: provider, typeIdentifier: UTType.plainText.identifier)
            guard let data, !data.isEmpty,
                  let text = String(data: data, encoding: .utf8),
                  text.range(of: "<html", options: .caseInsensitive) != nil
                    || text.range(of: "<!doctype html", options: .caseInsensitive) != nil
            else { return false }

            let inbox = try SharedInbox.ensureInbox()
            let destination = inbox.appendingPathComponent("Shared Page \(Int(Date().timeIntervalSince1970)).html")
            try data.write(to: destination, options: .atomic)
            return true
        }

        return false
    }

    private func name(of provider: NSItemProvider) -> String {
        provider.suggestedName ?? "item"
    }

    // MARK: - NSItemProvider helpers

    private func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                // The payload can arrive as a URL, Data, or a string.
                let url: URL?
                switch item {
                case let value as URL:
                    url = value
                case let value as Data:
                    url = URL(dataRepresentation: value, relativeTo: nil)
                case let value as String:
                    url = URL(string: value)
                default:
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    private func loadData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                switch item {
                case let value as Data:
                    continuation.resume(returning: value)
                case let value as String:
                    continuation.resume(returning: value.data(using: .utf8))
                case let value as URL:
                    continuation.resume(returning: try? Data(contentsOf: value))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Completion

    /// Finishes the request. Passing `nil` dismisses; a message shows the placeholder.
    private func finish(with message: String?) {
        if let message {
            showResult(message)
            // Let the message be readable before the sheet closes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
