import Foundation
import SwiftUI

/// Bridges a `Document` to a running `WebEngine`.
///
/// Owns the lifecycle of "serve this document's folder over HTTP and point a
/// web view at it", including tearing the mount back down when the user leaves.
@MainActor
final class DocumentSession: ObservableObject {

    let document: Document
    let engine = WebEngine()

    @Published private(set) var isReady = false
    @Published private(set) var startupError: String?

    /// The base URL the document is served from, e.g. `http://127.0.0.1:50123/r/<token>/`.
    @Published private(set) var baseURL: URL?

    private let server: LocalHTTPServer
    private let token: String

    init(document: Document, server: LocalHTTPServer) {
        self.document = document
        self.server = server
        self.token = UUID().uuidString
    }

    /// Mounts the document folder and loads its entry file.
    func start() {
        guard !isReady else { return }

        // Guard against a document whose files disappeared from the Files app.
        guard FileManager.default.fileExists(atPath: document.entryURL.path) else {
            startupError = "This document’s files are missing. it may have been deleted from the Files app."
            return
        }

        guard server.port != 0 else {
            startupError = "The local server isn’t running."
            return
        }

        let prefix = server.mount(directory: document.folderURL, token: token)
        guard let url = URL(string: "http://127.0.0.1:\(server.port)\(prefix)") else {
            startupError = "The document’s address could not be built."
            return
        }

        baseURL = url
        engine.load(documentBaseURL: url, entryPath: document.entryRelativePath)
        isReady = true
    }

    /// Releases the mount so no other document can address these files.
    func stop() {
        server.unmount(token: token)
        isReady = false
        baseURL = nil
    }

    var displayTitle: String {
        let engineTitle = engine.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return engineTitle.isEmpty ? document.displayTitle : engineTitle
    }
}
