import XCTest
import CommonCrypto
@testable import PagePocket

/// Unit tests for the pieces the UI tests cannot reach directly: path
/// resolution and traversal defence in the HTTP server, MIME correctness for
/// ES modules, ZIP parsing, and entry-file selection.
final class LocalHTTPServerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-server-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try "<html><body>hi</body></html>".write(
            to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body{}".write(
            to: root.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)

        // A sibling directory that must never be reachable from the mount.
        let secretDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-secret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        try "TOP SECRET".write(
            to: secretDir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        self.secretURL = secretDir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        if let secretURL { try? FileManager.default.removeItem(at: secretURL) }
    }

    private var secretURL: URL!

    // MARK: - Serving

    func testServesFileOverLoopback() throws {
        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }
        let prefix = server.mount(directory: root, token: "test-\(UUID().uuidString)")

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(prefix)index.html"))
        let (data, response) = try synchronousGet(url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<html><body>hi</body></html>")
    }

    func testServesCorrectMimeTypeForJavaScript() throws {
        // ES modules are rejected unless JavaScript is served as a JS MIME type,
        // so this is the difference between modules working and not.
        try "export const a = 1;".write(
            to: root.appendingPathComponent("mod.js"), atomically: true, encoding: .utf8)

        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }
        let prefix = server.mount(directory: root, token: "mime-\(UUID().uuidString)")

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(prefix)mod.js"))
        let (_, response) = try synchronousGet(url)

        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        XCTAssertEqual(contentType, "text/javascript; charset=utf-8")
    }

    func testMissingFileReturns404() throws {
        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }
        let prefix = server.mount(directory: root, token: "missing-\(UUID().uuidString)")

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(prefix)nope.html"))
        let (_, response) = try synchronousGet(url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    func testUnknownTokenIsRejected() throws {
        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }

        // A token that was never mounted must not resolve.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/r/never-mounted/index.html"))
        let (_, response) = try synchronousGet(url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    func testDirectoryServesIndexHTML() throws {
        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }
        let prefix = server.mount(directory: root, token: "dir-\(UUID().uuidString)")

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(prefix)"))
        let (data, response) = try synchronousGet(url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("hi"),
                      "A directory request should fall back to index.html.")
    }

    // MARK: - Security

    func testPathTraversalIsBlocked() throws {
        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }
        let prefix = server.mount(directory: root, token: "trav-\(UUID().uuidString)")

        // Every one of these must fail to escape the mount.
        let attacks = [
            "\(prefix)../\(secretURL.lastPathComponent)/secret.txt",
            "\(prefix)..%2F\(secretURL.lastPathComponent)%2Fsecret.txt",
            "\(prefix)%2e%2e%2f\(secretURL.lastPathComponent)%2fsecret.txt",
            "\(prefix)....//\(secretURL.lastPathComponent)/secret.txt"
        ]

        for attack in attacks {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(attack)"),
                                    "Could not build URL for \(attack)")
            let (data, response) = try synchronousGet(url)
            let body = String(decoding: data, as: UTF8.self)

            XCTAssertFalse(body.contains("TOP SECRET"),
                           "Path traversal succeeded for: \(attack)")
            XCTAssertNotEqual((response as? HTTPURLResponse)?.statusCode, 200,
                              "Traversal should not return 200 for: \(attack)")
        }
    }

    func testUnmountedTokenStopsServing() throws {
        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }
        let token = "unmount-\(UUID().uuidString)"
        let prefix = server.mount(directory: root, token: token)

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(prefix)index.html"))
        XCTAssertEqual((try synchronousGet(url).1 as? HTTPURLResponse)?.statusCode, 200)

        server.unmount(token: token)

        let (_, response) = try synchronousGet(url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404,
                       "After unmounting, the document's files must not be reachable.")
    }

    // MARK: - Helper

    /// Performs a GET and waits for it, since the tests are synchronous.
    private func synchronousGet(_ url: URL) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 15) == .success else {
            throw URLError(.timedOut)
        }

        switch try XCTUnwrap(result) {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

// MARK: - MIME types

final class MimeTypesTests: XCTestCase {

    func testJavaScriptTypesAreModuleCompatible() {
        for ext in ["js", "mjs", "cjs"] {
            let type = MimeTypes.contentType(forPathExtension: ext)
            XCTAssertTrue(type.contains("javascript"),
                          ".\(ext) must be served as JavaScript or ES modules fail, got: \(type)")
        }
    }

    func testCommonWebTypes() {
        XCTAssertTrue(MimeTypes.contentType(forPathExtension: "css").hasPrefix("text/css"))
        XCTAssertTrue(MimeTypes.contentType(forPathExtension: "html").hasPrefix("text/html"))
        XCTAssertTrue(MimeTypes.contentType(forPathExtension: "json").contains("json"))
        XCTAssertTrue(MimeTypes.contentType(forPathExtension: "svg").contains("svg"))
        XCTAssertEqual(MimeTypes.contentType(forPathExtension: "wasm"), "application/wasm")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(MimeTypes.contentType(forPathExtension: "HTML"),
                       MimeTypes.contentType(forPathExtension: "html"))
        XCTAssertEqual(MimeTypes.contentType(forPathExtension: "JS"),
                       MimeTypes.contentType(forPathExtension: "js"))
    }

    func testUnknownFallsBackToOctetStream() {
        XCTAssertEqual(MimeTypes.contentType(forPathExtension: "qqq"), "application/octet-stream")
    }

    func testCompressibleClassification() {
        XCTAssertTrue(MimeTypes.isCompressible("text/html; charset=utf-8"))
        XCTAssertTrue(MimeTypes.isCompressible("text/javascript; charset=utf-8"))
        XCTAssertFalse(MimeTypes.isCompressible("image/png"))
    }
}

// MARK: - ZIP extraction

final class ZipExtractorTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testRejectsNonZipData() throws {
        let bogus = workDir.appendingPathComponent("notazip.zip")
        try Data("this is definitely not a zip file".utf8).write(to: bogus)

        let destination = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ZipExtractor.extract(archiveAt: bogus, to: destination)) { error in
            guard case ZipExtractor.ZipError.notAZip = error else {
                return XCTFail("Expected .notAZip, got \(error)")
            }
        }
    }

    func testRejectsTruncatedArchive() throws {
        // A valid EOCD signature followed by nonsense offsets.
        var data = Data([0x50, 0x4b, 0x05, 0x06])
        data.append(Data(repeating: 0, count: 18))
        // Claim 5 entries starting far past the end of the file.
        data[10] = 5
        data[16] = 0xFF
        data[17] = 0xFF

        let archive = workDir.appendingPathComponent("truncated.zip")
        try data.write(to: archive)

        let destination = workDir.appendingPathComponent("out2", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ZipExtractor.extract(archiveAt: archive, to: destination)) { error in
            guard case ZipExtractor.ZipError.truncated = error else {
                return XCTFail("Expected .truncated, got \(error)")
            }
        }
    }

    func testExtractsDeflateArchiveWithNestedFoldersAndBinaryData() throws {
        // Deflate is the compression method that matters; this archive contains
        // nested directories and a 4 KB random binary file, so a bug in the
        // offset arithmetic or inflate size handling will corrupt bytes.
        let archive = try XCTUnwrap(fixtureURL("bundle-deflate"), "Missing test fixture.")
        let destination = workDir.appendingPathComponent("deflate", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try ZipExtractor.extract(archiveAt: archive, to: destination)

        let fm = FileManager.default
        let index = destination.appendingPathComponent("index.html")
        XCTAssertTrue(fm.fileExists(atPath: index.path), "index.html should be extracted.")

        let html = try String(contentsOf: index, encoding: .utf8)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"), "HTML content should survive intact.")

        // Deeply nested assets must keep their structure.
        for relative in ["assets/a.js", "assets/s.css", "assets/img/deep/nested.txt"] {
            XCTAssertTrue(
                fm.fileExists(atPath: destination.appendingPathComponent(relative).path),
                "\(relative) should be extracted at its original path."
            )
        }

        // Binary integrity is the real test of the inflate path.
        let binary = destination.appendingPathComponent("assets/img/binary.bin")
        let data = try Data(contentsOf: binary)
        XCTAssertEqual(data.count, 4096, "Binary file should be exactly 4096 bytes.")

        XCTAssertEqual(
            Self.sha256Hex(data),
            "a6241a20007890f0a460cc2bf5dde21e0c8ba7d08d04b105bf06d084f8b1bc12",
            "Extracted binary must be byte-identical to the original."
        )

        // The archive holds 9 entries: 6 real files plus 3 directory markers
        // ("assets/", "assets/img/", "assets/img/deep/"). Directory markers must
        // become directories, never zero-byte files, so count regular files only.
        var regularFileCount = 0
        if let enumerator = fm.enumerator(at: destination,
                                          includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true { regularFileCount += 1 }
            }
        }

        XCTAssertEqual(
            regularFileCount, 6,
            "Only the archive's 6 real files should be written. Found \(regularFileCount)."
        )

        for directory in ["assets", "assets/img"] {
            var isDir: ObjCBool = false
            let path = destination.appendingPathComponent(directory).path
            XCTAssertTrue(fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue,
                          "\(directory) should exist as a directory.")
        }
    }

    func testExtractsStoredUncompressedArchive() throws {
        // Method 0 (stored) takes a different code path from deflate.
        let archive = try XCTUnwrap(fixtureURL("bundle-stored"), "Missing test fixture.")
        let destination = workDir.appendingPathComponent("stored", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try ZipExtractor.extract(archiveAt: archive, to: destination)

        let extracted = destination.appendingPathComponent("stored.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))
        XCTAssertEqual(
            try String(contentsOf: extracted, encoding: .utf8),
            "stored entry",
            "Stored entries should be written verbatim."
        )
    }

    func testExtractedBundleIsUsableAsADocument() throws {
        // End-to-end through the importer's own logic: extract, then confirm the
        // entry-file finder picks the right document out of the tree.
        let archive = try XCTUnwrap(fixtureURL("bundle-deflate"))
        let destination = workDir.appendingPathComponent("usable", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try ZipExtractor.extract(archiveAt: archive, to: destination)

        let entry = try XCTUnwrap(DocumentStore.findEntryFile(in: destination))
        XCTAssertEqual(entry.lastPathComponent, "index.html")
        XCTAssertEqual(DocumentStore.relativePath(of: entry, in: destination), "index.html")

        let summary = DocumentStore.measure(folder: destination)
        XCTAssertTrue(summary.contains("files"), "Got: \(summary)")
    }

    // MARK: - Helpers

    /// Locates a fixture in the test bundle.
    ///
    /// The fixtures are added as a folder reference, so they land in a
    /// `Fixtures/` subdirectory — `url(forResource:withExtension:)` only
    /// searches the bundle root, hence the explicit subdirectory.
    private func fixtureURL(_ name: String) -> URL? {
        let bundle = Bundle(for: type(of: self))
        if let direct = bundle.url(forResource: name, withExtension: "zip") {
            return direct
        }
        return bundle.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures")
    }

    /// Minimal SHA-256, so the test does not depend on CryptoKit availability.
    private static func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            var ctx = CC_SHA256_CTX()
            CC_SHA256_Init(&ctx)
            if let base = buffer.baseAddress {
                CC_SHA256_Update(&ctx, base, CC_LONG(buffer.count))
            }
            CC_SHA256_Final(&hash, &ctx)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Entry file selection

final class EntryFileSelectionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ contents: String = "<html></html>") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testPrefersIndexHTML() throws {
        try write("other.html")
        try write("index.html")

        let entry = try XCTUnwrap(DocumentStore.findEntryFile(in: root))
        XCTAssertEqual(entry.lastPathComponent, "index.html")
    }

    func testPrefersShallowestIndex() throws {
        try write("deep/nested/index.html")
        try write("index.html")

        let entry = try XCTUnwrap(DocumentStore.findEntryFile(in: root))
        XCTAssertEqual(DocumentStore.relativePath(of: entry, in: root), "index.html")
    }

    func testFallsBackToAnyHTMLWhenNoIndex() throws {
        try write("chapter2.html")
        try write("chapter1.html")

        let entry = try XCTUnwrap(DocumentStore.findEntryFile(in: root))
        XCTAssertEqual(entry.lastPathComponent, "chapter1.html",
                       "Should be deterministic when there is no index file.")
    }

    func testReturnsNilWhenNoHTML() throws {
        try write("readme.txt", "no html here")
        XCTAssertNil(try DocumentStore.findEntryFile(in: root))
    }

    func testIgnoresMacOSXJunk() throws {
        try write("__MACOSX/._index.html")
        XCTAssertNil(try DocumentStore.findEntryFile(in: root),
                     "Resource-fork entries should not be treated as documents.")
    }

    func testRelativePathComputation() throws {
        try write("a/b/c.html")
        let nested = root.appendingPathComponent("a/b/c.html")

        XCTAssertEqual(DocumentStore.relativePath(of: nested, in: root), "a/b/c.html")
    }

    func testMeasureReportsFileCountAndSize() throws {
        try write("index.html", String(repeating: "x", count: 500))
        try write("assets/app.js", String(repeating: "y", count: 500))

        let summary = DocumentStore.measure(folder: root)
        XCTAssertTrue(summary.contains("2 files"), "Got: \(summary)")
        XCTAssertTrue(summary.contains("KB") || summary.contains("bytes"), "Got: \(summary)")
    }
}
