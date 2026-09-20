import Foundation
import Network

/// A minimal, read-only HTTP/1.1 server bound to the loopback interface.
///
/// **Why a web server instead of `loadFileURL`?**
/// Loading a file directly gives a `file://` origin, which WebKit treats as
/// opaque: `fetch()`, ES modules, service workers, `XMLHttpRequest` and even
/// `localStorage` are blocked or unreliable. Serving the same folder over
/// `http://127.0.0.1` gives the page a real, secure-enough origin, so ordinary
/// web apps — including ones that fetch data or use `<script type="module">` —
/// behave exactly as they do on the web.
///
/// The listener binds `127.0.0.1` directly and only ever serves files beneath a
/// registered root, so its own traffic cannot leave the device.
///
/// That constrains the *server* only. The web view rendering those documents can
/// still reach the network, so responses carry a Content-Security-Policy and
/// `WebEngine` cancels navigation away from the document. See `LocalHTTPServer`
/// and `WebEngine` for the enforced limits.
final class LocalHTTPServer {

    /// Process-wide instance.
    ///
    /// One server serves every document, each under its own random path token.
    /// It is shared because a view needs it while it is being constructed,
    /// before SwiftUI's environment is available.
    static let shared = LocalHTTPServer()

    /// A directory tree exposed under a URL prefix.
    private struct Mount {
        let root: URL
    }

    private init() {}

    private let queue = DispatchQueue(label: "com.pagepocket.http", qos: .userInitiated)
    private var listener: NWListener?
    private var mounts: [String: Mount] = [:]
    private let mountsLock = NSLock()

    /// The port the server is listening on. Only valid after ``start()`` succeeds.
    private(set) var port: UInt16 = 0

    /// Serializes "is this the first request?" bookkeeping.
    private var hasLoggedFirstRequest = false

    // MARK: - Lifecycle

    /// Starts listening on loopback and returns the port it was assigned.
    ///
    /// - Throws: ``ServerError`` if the listener cannot be created or fails to
    ///   reach the `.ready` state.
    @discardableResult
    func start() throws -> UInt16 {
        if listener != nil { return port }

        let parameters = NWParameters.tcp
        // Pin the bind address itself, not just the interface. `requiredInterfaceType`
        // constrains which interface is *used*; `requiredLocalEndpoint` is what
        // makes the socket bind 127.0.0.1 by construction, so "loopback only" is
        // enforced by the kernel rather than inferred from a filter.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        parameters.includePeerToPeer = false
        // (Removed `allowLocalEndpointReuse`: the port is kernel-assigned and
        // ephemeral, so there is nothing to reuse, and if it maps to
        // SO_REUSEPORT it would let another local process bind the same port.)

        let listener: NWListener
        do {
            // Omitting the port asks the kernel for an ephemeral one.
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerError.couldNotCreateListener(error.localizedDescription)
        }

        let ready = DispatchSemaphore(value: 0)
        var startupError: String?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupError = error.localizedDescription
                ready.signal()
            case .cancelled:
                startupError = startupError ?? "Listener cancelled during startup."
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        self.listener = listener
        listener.start(queue: queue)

        // Give the listener a moment to become ready; the kernel assigns the
        // ephemeral port during this transition.
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            self.listener = nil
            throw ServerError.timedOut
        }

        if let startupError {
            listener.cancel()
            self.listener = nil
            throw ServerError.listenerFailed(startupError)
        }

        guard let assignedPort = listener.port?.rawValue, assignedPort != 0 else {
            listener.cancel()
            self.listener = nil
            throw ServerError.noPortAssigned
        }

        port = assignedPort
        return assignedPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: - Mounts

    /// Exposes `directory` at `/r/<token>/`. Returns the URL prefix to use.
    ///
    /// Each document gets its own random token, which prevents one document from
    /// addressing another's files by *guessing a path*.
    ///
    /// Note this is not document isolation in general: every document served on
    /// this port shares one web origin (same scheme, host and port), so they
    /// share localStorage and IndexedDB unless each gets its own data store —
    /// which `WebEngine` arranges.
    @discardableResult
    func mount(directory: URL, token: String) -> String {
        mountsLock.lock()
        mounts[token] = Mount(root: directory.standardizedFileURL)
        mountsLock.unlock()
        return "/r/\(token)/"
    }

    func unmount(token: String) {
        mountsLock.lock()
        mounts.removeValue(forKey: token)
        mountsLock.unlock()
    }

    /// Resolves a request path to a file inside a mounted root.
    private func resolve(path: String) -> (url: URL, mountRoot: URL)? {
        // Path looks like /r/<token>/rest/of/path
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2, components[0] == "r" else { return nil }
        let token = components[1]

        mountsLock.lock()
        let mount = mounts[token]
        mountsLock.unlock()
        guard let mount else { return nil }

        let remainder = components.dropFirst(2).joined(separator: "/")
        let decoded = remainder.removingPercentEncoding ?? remainder

        // Reject traversal outright rather than trying to normalise it away.
        if decoded.contains("..") || decoded.contains("\0") { return nil }

        var candidate = mount.root
        if !decoded.isEmpty {
            for piece in decoded.split(separator: "/", omittingEmptySubsequences: true) {
                let segment = String(piece)
                if segment == "." || segment == ".." { return nil }
                candidate.appendPathComponent(segment, isDirectory: false)
            }
        }

        // Final containment check: the resolved path must still be inside the root.
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = mount.root.resolvingSymlinksInPath().path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            return nil
        }

        return (resolved, mount.root)
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if let error {
                _ = error
                connection.cancel()
                return
            }

            // Headers end at the first blank line; requests here never carry a body.
            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8))
                ?? accumulated.range(of: Data("\n\n".utf8)) {
                let headerData = accumulated.subdata(in: accumulated.startIndex..<headerEnd.lowerBound)
                let headerText = String(decoding: headerData, as: UTF8.self)
                self.respond(to: headerText, on: connection)
                return
            }

            // Guard against an unbounded header block.
            if accumulated.count > 128 * 1024 || isComplete {
                self.sendSimple(status: 400, reason: "Bad Request",
                                body: "Malformed request.".data(using: .utf8) ?? Data(),
                                contentType: "text/plain; charset=utf-8",
                                on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: accumulated)
        }
    }

    private func respond(to headerText: String, on connection: NWConnection) {
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        let firstLine = lines.first.map(String.init) ?? ""

        // e.g. "GET /r/abc/index.html HTTP/1.1"
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendSimple(status: 400, reason: "Bad Request", body: Data(),
                       contentType: "text/plain; charset=utf-8", on: connection)
            return
        }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        guard method == "GET" || method == "HEAD" else {
            sendSimple(status: 405, reason: "Method Not Allowed",
                       body: "Only GET and HEAD are supported.".data(using: .utf8) ?? Data(),
                       contentType: "text/plain; charset=utf-8", on: connection, headOnly: method == "HEAD")
            return
        }

        // Strip query and fragment before resolving on disk.
        var path = rawTarget
        if let hashIndex = path.firstIndex(of: "#") { path = String(path[path.startIndex..<hashIndex]) }
        if let queryIndex = path.firstIndex(of: "?") { path = String(path[path.startIndex..<queryIndex]) }
        if !path.hasPrefix("/") { path = "/" + path }

        guard var (fileURL, _) = resolve(path: path) else {
            sendSimple(status: 404, reason: "Not Found",
                       body: notFoundPage(path: path).data(using: .utf8) ?? Data(),
                       contentType: "text/html; charset=utf-8", on: connection, headOnly: method == "HEAD")
            return
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            sendSimple(status: 404, reason: "Not Found",
                       body: notFoundPage(path: path).data(using: .utf8) ?? Data(),
                       contentType: "text/html; charset=utf-8", on: connection, headOnly: method == "HEAD")
            return
        }

        // Directory: prefer index.html so "/" works like a normal site root.
        if isDirectory.boolValue {
            let index = fileURL.appendingPathComponent("index.html")
            if fileManager.fileExists(atPath: index.path) {
                fileURL = index
            } else {
                let listing = directoryListing(at: fileURL, requestPath: path)
                sendSimple(status: 200, reason: "OK",
                           body: listing.data(using: .utf8) ?? Data(),
                           contentType: "text/html; charset=utf-8", on: connection, headOnly: method == "HEAD")
                return
            }
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
            sendSimple(status: 500, reason: "Internal Server Error",
                       body: Data(), contentType: "text/plain; charset=utf-8", on: connection)
            return
        }

        let contentType = MimeTypes.contentType(for: fileURL)
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }

        // Read the file. HTML apps are small; a single read keeps this simple
        // and lets us honour Range requests for <video>/<audio> seeking.
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            sendSimple(status: 403, reason: "Forbidden",
                       body: Data(), contentType: "text/plain; charset=utf-8", on: connection)
            return
        }
        defer { try? handle.close() }

        if let rangeHeader, let range = parseRange(rangeHeader, fileSize: fileSize) {
            let length = range.upperBound - range.lowerBound + 1
            do {
                try handle.seek(toOffset: UInt64(range.lowerBound))
                let data = try handle.read(upToCount: Int(length)) ?? Data()
                let headers = [
                    "HTTP/1.1 206 Partial Content",
                    "Content-Type: \(contentType)",
                    "Content-Length: \(data.count)",
                    "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)",
                    "Accept-Ranges: bytes",
                    "X-Content-Type-Options: nosniff",
                    "Cache-Control: no-store",
                    "Connection: close"
                ]
                send(headers: headers, body: method == "HEAD" ? Data() : data, on: connection)
            } catch {
                sendSimple(status: 500, reason: "Internal Server Error", body: Data(),
                           contentType: "text/plain; charset=utf-8", on: connection)
            }
            return
        }

        // An empty file legitimately reads back as nil/empty; that is not an error.
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            sendSimple(status: 500, reason: "Internal Server Error", body: Data(),
                       contentType: "text/plain; charset=utf-8", on: connection)
            return
        }

        var headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType)",
            "Content-Length: \(data.count)",
            "Accept-Ranges: bytes",
            "X-Content-Type-Options: nosniff",
            // Documents are edited and re-imported constantly; never cache.
            "Cache-Control: no-store, must-revalidate",
            "Connection: close"
        ]

        // Confine the document to its own origin.
        //
        // Imported HTML is untrusted, and without this a page can POST everything
        // in its folder to a remote server. `connect-src 'self'` blocks fetch,
        // XHR, WebSocket and sendBeacon to anywhere but this mount; the rest keeps
        // the document self-contained while still allowing inline and blob assets,
        // which real single-file HTML depends on.
        if contentType.hasPrefix("text/html") || contentType.hasPrefix("application/xhtml") {
            headers.append(
                "Content-Security-Policy: "
                + "default-src 'self' blob: data: 'unsafe-inline' 'unsafe-eval'; "
                + "connect-src 'self' blob: data:; "
                + "img-src 'self' blob: data:; "
                + "media-src 'self' blob: data:; "
                + "font-src 'self' data:; "
                + "style-src 'self' blob: data: 'unsafe-inline'; "
                + "script-src 'self' blob: data: 'unsafe-inline' 'unsafe-eval'; "
                + "frame-src 'self' blob: data:; "
                + "worker-src 'self' blob:; "
                + "form-action 'none'; "
                + "frame-ancestors 'self'; "
                + "base-uri 'self'"
            )
        }

        send(headers: headers, body: method == "HEAD" ? Data() : data, on: connection)
    }

    // MARK: - Response helpers

    private func sendSimple(status: Int, reason: String, body: Data, contentType: String,
                            on connection: NWConnection, headOnly: Bool = false) {
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "X-Content-Type-Options: nosniff",
            "Cache-Control: no-store",
            "Connection: close"
        ]
        send(headers: headers, body: headOnly ? Data() : body, on: connection)
    }

    private func send(headers: [String], body: Data, on connection: NWConnection) {
        var response = Data(headers.joined(separator: "\r\n").utf8)
        response.append(Data("\r\n\r\n".utf8))
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Parses a single-range `bytes=a-b` header.
    private func parseRange(_ header: String, fileSize: Int64) -> ClosedRange<Int64>? {
        // A zero-byte file has no valid byte range. Without this guard the suffix
        // branch below would build `0...(-1)`, and constructing an invalid Range
        // is a Swift runtime trap (not a throwable error) — on the server queue
        // that kills the whole process. `fetch('empty.txt', {headers:{Range:'bytes=-1'}})`
        // from any imported page was therefore a one-line remote crash.
        guard fileSize > 0 else { return nil }

        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        // Multipart ranges are not supported; fall back to a full response.
        guard !spec.contains(",") else { return nil }

        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }

        let startText = bounds[0].trimmingCharacters(in: .whitespaces)
        let endText = bounds[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            // Suffix range: last N bytes.
            guard let suffixLength = Int64(endText), suffixLength > 0 else { return nil }
            let start = max(0, fileSize - suffixLength)
            return start...(fileSize - 1)
        }

        guard let start = Int64(startText), start >= 0, start < fileSize else { return nil }
        let end = endText.isEmpty ? fileSize - 1 : min(Int64(endText) ?? (fileSize - 1), fileSize - 1)
        guard end >= start else { return nil }
        return start...end
    }

    // MARK: - Generated pages

    private func notFoundPage(path: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          body{font:-apple-system,system-ui,sans-serif;background:#111;color:#eee;margin:0;
               display:flex;align-items:center;justify-content:center;height:100vh;padding:24px;text-align:center}
          code{background:#222;padding:2px 6px;border-radius:4px;font-size:14px;word-break:break-all}
          h1{font-size:20px;margin:0 0 8px}
          p{color:#999;font-size:14px;line-height:1.5;margin:6px 0}
        </style></head>
        <body><div>
          <h1>File not found</h1>
          <p><code>\(Self.escapeHTML(path))</code></p>
          <p>If this page needs CSS, JavaScript or images, import the whole folder
          rather than a single file so its assets come along.</p>
        </div></body></html>
        """
    }

    private func directoryListing(at directory: URL, requestPath: String) -> String {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let rows = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item -> String in
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = item.lastPathComponent + (isDirectory ? "/" : "")
            let href = requestPath.hasSuffix("/") ? requestPath + item.lastPathComponent
                                               : requestPath + "/" + item.lastPathComponent
            return "<li><a href=\"\(Self.escapeHTML(href))\">\(Self.escapeHTML(name))</a></li>"
        }.joined()

        return """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          body{font:-apple-system,system-ui,sans-serif;background:#111;color:#eee;margin:0;padding:24px}
          h1{font-size:16px;color:#999;font-weight:600}
          ul{list-style:none;padding:0}
          li{padding:10px 0;border-bottom:1px solid #222}
          a{color:#4da3ff;text-decoration:none}
        </style></head>
        <body><h1>\(Self.escapeHTML(requestPath))</h1><ul>\(rows)</ul></body></html>
        """
    }

    static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Errors

    enum ServerError: LocalizedError {
        case couldNotCreateListener(String)
        case listenerFailed(String)
        case timedOut
        case noPortAssigned

        var errorDescription: String? {
            switch self {
            case .couldNotCreateListener(let detail):
                return "Could not create the local server: \(detail)"
            case .listenerFailed(let detail):
                return "The local server failed to start: \(detail)"
            case .timedOut:
                return "The local server timed out while starting."
            case .noPortAssigned:
                return "The local server did not receive a port."
            }
        }
    }
}
