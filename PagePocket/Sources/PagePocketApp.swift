import SwiftUI
import UIKit

/// App-wide services: the local server and the document store.
///
/// The server starts once for the whole process, because every document is
/// served from the same loopback port under its own random token.
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var serverError: String?
    @Published private(set) var isServerRunning = false

    let server = LocalHTTPServer.shared
    let store = DocumentStore()

    /// A document opened from outside the app (Files app, another app) that
    /// still needs to be imported and shown.
    @Published var pendingImportURL: URL?

    init() {
        startServer()
        TemporaryFiles.cleanUp()

        // Keep the UI stable while automated tests are driving it: continuous
        // animation makes accessibility snapshots go stale mid-query.
        if ProcessInfo.processInfo.arguments.contains("-UITests") {
            UIView.setAnimationsEnabled(false)
            Log.app.notice("Running with UI-test stability settings.")
        }
    }

    private func startServer() {
        do {
            let port = try server.start()
            isServerRunning = true
            serverError = nil
            // Logged unconditionally: this line is what automated verification
            // checks to confirm the loopback server came up.
            Log.server.notice("Local server listening on http://127.0.0.1:\(port)/")
        } catch {
            isServerRunning = false
            serverError = error.localizedDescription
            Log.server.error("Local server failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Handles a file handed to us by another app or the Files app.
    ///
    /// The URL is security-scoped for the duration of this call only, so the
    /// file is copied into the library immediately rather than referenced later.
    func handleIncomingFile(_ url: URL) async {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        // A document handed over from our own Documents directory (which happens
        // when the system routes an in-place "Open in PagePocket" back to us) is
        // already where adoptLooseFiles looks, so importing it here as well
        // would produce two copies of the same document.
        if url.isFileURL, Self.isInsideDocuments(url) {
            Log.library.notice("Incoming file already in Documents; letting the library adopt it.")
            store.adoptLooseFiles()
            return
        }

        do {
            _ = try await store.importItem(at: url)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    /// Whether a URL points inside the app's own Documents directory.
    private static func isInsideDocuments(_ url: URL) -> Bool {
        let documents = DocumentStore.documentsRoot.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == documents || candidate.hasPrefix(documents + "/")
    }
}

@main
struct PagePocketApp: App {

    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(appModel)
                .environmentObject(appModel.store)
                .onOpenURL { url in
                    Task { await appModel.handleIncomingFile(url) }
                }
        }
    }
}
