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

    /// A document opened from outside the app (Files app, another app) that
    /// should be shown as soon as its import finishes.
    ///
    /// Tapping an HTML file in the Files app means "show me this file" — landing
    /// on the library instead, with the file merely listed, reads as a failure
    /// even though the import worked.
    @Published var documentToPresent: Document?

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
            Log.library.notice("Incoming file already in Documents; adopting and presenting it.")

            // Adopting is asynchronous, so wait for the document to appear and
            // then present it. Without this the user taps a file and lands on
            // the library with no sign that anything happened.
            store.adoptLooseFiles()
            await presentExistingDocument(named: url.lastPathComponent)
            return
        }

        do {
            let document = try await store.importItem(at: url)
            // Take the user straight to what they tapped, rather than leaving
            // them on the library to find it themselves.
            documentToPresent = document
            Log.app.notice("Presenting incoming “\(document.displayTitle, privacy: .public)”.")
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    /// Waits briefly for `fileName` to be adopted, then asks the UI to show it.
    ///
    /// Adoption copies files on a background task, so the document does not
    /// exist the instant the scan starts.
    private func presentExistingDocument(named fileName: String) async {
        // Compare against everything the library might have recorded: the file
        // is stored as "<name>/index.html", so `originalFileName` can be either
        // the bare filename or the generated folder name depending on the route
        // it took into the library.
        let stem = (fileName as NSString).deletingPathExtension
        let tidied = DocumentStore.friendlyTitle(from: fileName)

        for _ in 0..<25 {
            let match = store.documents.first { document in
                document.originalFileName == fileName
                    || document.originalFileName == stem
                    || document.displayTitle == fileName
                    || document.displayTitle == stem
                    || document.displayTitle == tidied
                    || document.title == tidied
            }

            if let match {
                documentToPresent = match
                Log.app.notice("Presenting adopted “\(match.displayTitle, privacy: .public)”.")
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        Log.app.error("Could not find an adopted document for “\(fileName, privacy: .public)”.")
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
