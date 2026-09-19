import SwiftUI

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

    /// Handles a file handed to us by another app.
    ///
    /// The URL is security-scoped for the duration of this call only, so the
    /// file is copied into the library immediately rather than referenced later.
    func handleIncomingFile(_ url: URL) async {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            _ = try await store.importItem(at: url)
        } catch {
            store.lastError = error.localizedDescription
        }
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
