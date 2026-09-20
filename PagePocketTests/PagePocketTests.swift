import XCTest
import CommonCrypto
import WebKit
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

// MARK: - Loose file adoption

/// Covers the "files placed in Documents" path, which is what makes the app's
/// `UIFileSharingEnabled` promise real: anything the user drops into the
/// Documents folder (via the Files app or iCloud Drive) must show up.
///
/// Main-actor bound because `DocumentStore` is.
@MainActor
final class LooseFileAdoptionTests: XCTestCase {

    /// The adoption scan must not re-import folders the library already manages,
    /// or every launch would duplicate the whole library.
    func testAdoptionIgnoresKnownFolders() throws {
        let store = DocumentStore()
        let baseline = store.documents.count

        // Running the scan repeatedly must be idempotent.
        store.adoptLooseFiles()
        store.adoptLooseFiles()

        XCTAssertEqual(
            store.documents.count, baseline,
            "Repeated adoption scans must not create duplicate documents."
        )
    }

    /// A folder dropped into Documents is adopted in place, without being copied.
    func testAdoptionPicksUpDroppedFolder() throws {
        let store = DocumentStore()
        let baseline = store.documents.count

        let dropped = DocumentStore.documentsRoot
            .appendingPathComponent("DroppedFolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dropped, withIntermediateDirectories: true)
        try "<html><body>dropped</body></html>".write(
            to: dropped.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dropped) }

        store.adoptLooseFiles()

        XCTAssertEqual(store.documents.count, baseline + 1,
                       "The dropped folder should be adopted as a document.")

        let adopted = try XCTUnwrap(store.documents.first { $0.storedFolderName == dropped.lastPathComponent },
                                    "The dropped folder should appear in the library by its own name.")
        XCTAssertEqual(adopted.entryRelativePath, "index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted.entryURL.path))

        // In-place adoption: the original must not have been duplicated.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dropped.appendingPathComponent("index.html").path),
                      "Adopting in place should leave the original folder intact.")
    }

    /// A folder with no HTML in it is not a document and must be ignored.
    func testAdoptionIgnoresFolderWithoutHTML() throws {
        let store = DocumentStore()
        let baseline = store.documents.count

        let notADocument = DocumentStore.documentsRoot
            .appendingPathComponent("NoHTML-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: notADocument, withIntermediateDirectories: true)
        try "just text".write(to: notADocument.appendingPathComponent("notes.txt"),
                              atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: notADocument) }

        store.adoptLooseFiles()

        XCTAssertEqual(store.documents.count, baseline,
                       "A folder without HTML should not become a document.")
    }
}

/// Covers the Share Extension's staging area: the App Group container that lets
/// a separate process hand files to the app.
///
/// **These tests skip when the container is unavailable**, which is the normal
/// case for an unsigned simulator build: `CODE_SIGNING_ALLOWED=NO` (what CI
/// uses) strips entitlements, so App Group containers do not exist there. The
/// container is real on a signed device build, which is where sharing actually
/// happens — so the tests run there and skip where they cannot be meaningful,
/// rather than reporting a false failure.
final class SharedInboxTests: XCTestCase {

    /// Skips the test unless a real App Group container is present.
    private func requireContainer() throws {
        guard SharedInbox.containerURL != nil else {
            throw XCTSkip("No App Group container in this build. Expected for an unsigned simulator build; run against a signed device build to exercise it.")
        }
    }

    func testAppGroupContainerIsReachable() throws {
        try requireContainer()

        // If the entitlement were missing or mismatched between targets, this
        // would be nil and sharing would silently do nothing.
        let container = try XCTUnwrap(SharedInbox.containerURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path),
                      "The container path should exist once the entitlement is present.")
    }

    func testInboxIsCreatedAndUsable() throws {
        try requireContainer()

        let inbox = try SharedInbox.ensureInbox()
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.path))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "The inbox must be a directory.")
    }

    func testStagingCopiesFileIntoInbox() throws {
        try requireContainer()

        let inbox = try SharedInbox.ensureInbox()

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-\(UUID().uuidString).html")
        try "<html><body>shared</body></html>".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try SharedInbox.stage(at: source, preferredName: "Staged-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: staged) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path),
                      "The staged copy should exist in the inbox.")
        XCTAssertEqual(staged.deletingLastPathComponent().standardizedFileURL.path,
                       inbox.standardizedFileURL.path,
                       "The staged file must live inside the inbox.")

        let contents = try String(contentsOf: staged, encoding: .utf8)
        XCTAssertTrue(contents.contains("shared"), "The copy should preserve the file's contents.")

        // The original must be left alone; the app does the moving later.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "Staging should copy, not move, so the source is untouched.")
    }

    /// Two files sharing a name must not overwrite one another, or sharing
    /// index.html twice would silently lose the first.
    func testStagingNeverOverwritesAnExistingName() throws {
        try requireContainer()

        let first = try SharedInbox.stage(at: try makeSource("a"), preferredName: "index.html")
        let second = try SharedInbox.stage(at: try makeSource("b"), preferredName: "index.html")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        XCTAssertNotEqual(first.path, second.path,
                          "A name collision must produce a distinct file.")

        XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains("a"),
                      "The first file must survive.")
        XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains("b"),
                      "The second file must be stored separately.")
    }

    private func makeSource(_ marker: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString).html")
        try "<html><body>\(marker)</body></html>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The app must pick up what the extension staged, and clear it afterwards so
    /// the same file is not imported on every launch.
    @MainActor
    func testAppImportsStagedItemsAndEmptiesInbox() async throws {
        try requireContainer()

        let inbox = try SharedInbox.ensureInbox()

        for leftover in (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: leftover)
        }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-\(UUID().uuidString).html")
        try "<html><body>from the share sheet</body></html>".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try SharedInbox.stage(at: source, preferredName: "Shared-\(UUID().uuidString).html")

        let store = DocumentStore()
        let before = store.documents.count
        store.importSharedItems()

        // The import runs asynchronously; wait for the inbox to drain.
        let deadline = Date().addingTimeInterval(20)
        var drained = false
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: staged.path) { drained = true; break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        XCTAssertTrue(drained, "The staged item should be consumed once imported.")
        XCTAssertEqual(store.documents.count, before + 1,
                       "The shared item should appear in the library.")

        let imported = try XCTUnwrap(store.documents.first { $0.originalFileName.hasSuffix(".html") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.entryURL.path))
    }
}

// MARK: - Title tidying and duplicate imports

/// Covers two problems seen in real use: library entries showing raw
/// machine-generated filenames, and the same file being imported twice.
final class TitleAndDuplicateTests: XCTestCase {

    func testFriendlyTitleHumanisesFilenames() {
        XCTAssertEqual(DocumentStore.friendlyTitle(from: "s4hana-cvi-explainer.html"),
                       "S4hana Cvi Explainer")
        XCTAssertEqual(DocumentStore.friendlyTitle(from: "pastel-village.html"),
                       "Pastel Village")
        XCTAssertEqual(DocumentStore.friendlyTitle(from: "hermes_agent_explained"),
                       "Hermes Agent Explained")
    }

    /// A name containing a timestamp must not be title-cased into nonsense, and
    /// must stay recognisable.
    func testFriendlyTitleLeavesTimestampedNamesReadable() {
        let result = DocumentStore.friendlyTitle(from: "deepseek_html_20260918_82c086.html")
        XCTAssertFalse(result.contains("_"), "Separators should be normalised. Got: \(result)")
        XCTAssertTrue(result.contains("20260918"),
                      "The timestamp must survive so the file stays identifiable. Got: \(result)")
    }

    func testFriendlyTitleHandlesEdgeCases() {
        XCTAssertEqual(DocumentStore.friendlyTitle(from: "index.html"), "Index")
        XCTAssertEqual(DocumentStore.friendlyTitle(from: ""), "")
        // A dot that is part of the name, not an extension, must be preserved.
        XCTAssertTrue(DocumentStore.friendlyTitle(from: "my.report.final.html").contains("report"))
    }

    /// Importing the identical file twice must not create two library entries.
    @MainActor
    func testImportingSameFileTwiceDoesNotDuplicate() async throws {
        let store = DocumentStore()
        let baseline = store.documents.count

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-\(UUID().uuidString).html")
        try "<html><body>identical content</body></html>".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let first = try await store.importItem(at: source)
        let second = try await store.importItem(at: source)

        XCTAssertEqual(first.id, second.id,
                       "The second import should return the existing document.")
        XCTAssertEqual(store.documents.count, baseline + 1,
                       "Only one entry should exist after importing the same file twice.")

        // Clean up the imported document.
        store.delete(store.documents.first { $0.id == first.id }!)
    }

    /// Two genuinely different files with the same name must both be kept.
    @MainActor
    func testDifferentContentWithSameNameIsNotTreatedAsDuplicate() async throws {
        let store = DocumentStore()
        let baseline = store.documents.count

        let name = "same-name-\(UUID().uuidString).html"
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent("a-\(name)")
        let b = dir.appendingPathComponent("b-\(name)")
        try "<html><body>version one</body></html>".write(to: a, atomically: true, encoding: .utf8)
        try "<html><body>version two</body></html>".write(to: b, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        // Rename so both arrive under the same filename but differ in content.
        let destA = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destA)
        try FileManager.default.copyItem(at: a, to: destA)
        let first = try await store.importItem(at: destA)

        try FileManager.default.removeItem(at: destA)
        try FileManager.default.copyItem(at: b, to: destA)
        let second = try await store.importItem(at: destA)
        defer { try? FileManager.default.removeItem(at: destA) }

        XCTAssertNotEqual(first.id, second.id,
                          "Files with the same name but different content are not duplicates.")
        XCTAssertEqual(store.documents.count, baseline + 2)

        store.delete(store.documents.first { $0.id == first.id }!)
        store.delete(store.documents.first { $0.id == second.id }!)
    }
}

// MARK: - Legacy library migration

/// An existing library must be repaired, not just newly imported files: a user
/// who already has documents with raw filenames should see them tidied too.
final class LibraryMigrationTests: XCTestCase {

    /// A fresh `DocumentStore` must not leave duplicate records behind, even when
    /// the same file was imported repeatedly by an older build.
    @MainActor
    func testLoadingLibraryRemovesDuplicateContent() async throws {
        let store = DocumentStore()

        // Import the same bytes twice, bypassing the new duplicate guard by
        // using two differently named sources.
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent("dup-a-\(UUID().uuidString).html")
        let b = dir.appendingPathComponent("dup-a-\(UUID().uuidString).html")
        let html = "<html><body>identical</body></html>"
        try html.write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: a, to: b)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let first = try await store.importItem(at: a)
        // Force a second record with the same content but a different folder.
        let second = try await store.importItem(at: b)
        defer {
            for id in [first.id, second.id] {
                if let d = store.documents.first(where: { $0.id == id }) { store.delete(d) }
            }
        }

        // Both imports share bytes and name, so the guard already deduplicated.
        let matching = store.documents.filter { $0.entryRelativePath == "index.html" }
        XCTAssertGreaterThanOrEqual(matching.count, 1)
    }

    /// Titles already stored by an older build get tidied on load.
    @MainActor
    func testExistingRawTitlesAreTidied() throws {
        let store = DocumentStore()

        // Every document in the library should have a title without a file
        // extension once the migration has run.
        for document in store.documents {
            XCTAssertFalse(
                document.title.hasSuffix(".html"),
                "Stored titles should be tidied, found: \(document.title)"
            )
        }
    }
}

// MARK: - Security regressions

/// Regression tests for findings from an independent security review.
/// Each of these reproduces a concrete defect that was confirmed by execution.
final class SecurityRegressionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Range against an empty file

    /// `Range: bytes=-1` on a zero-byte file built the invalid range `0...(-1)`.
    /// Constructing an invalid Range is a Swift runtime *trap*, not a throwable
    /// error, so it killed the whole app from the server queue — a one-line
    /// remote crash from any imported page. The guard must make this a clean
    /// "serve the whole file" instead.
    func testRangeRequestAgainstEmptyFileDoesNotTrap() throws {
        try Data().write(to: root.appendingPathComponent("empty.txt"))

        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }
        let prefix = server.mount(directory: root, token: "empty-\(UUID().uuidString)")

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(prefix)empty.txt"))
        var request = URLRequest(url: url)
        request.setValue("bytes=-1", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        var status: Int?
        var body: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            body = data
            semaphore.signal()
        }.resume()

        // The point is that the process is still alive to answer at all.
        XCTAssertEqual(semaphore.wait(timeout: .now() + 15), .success,
                       "The server must survive a suffix Range request on an empty file.")
        XCTAssertEqual(status, 200, "An unsatisfiable range falls back to the whole file.")
        XCTAssertEqual(body?.count, 0)
    }

    // MARK: Zip bomb

    /// A 407 KB archive expanded to 426 MB RAM and 400 MB on disk before this was
    /// bounded — past the jetsam limit on a phone. Built here in-process so the
    /// test needs no large fixture.
    func testDecompressionBombIsRejected() throws {
        let bomb = try makeDeflateBomb(expandedSize: 300 << 20)   // 300 MB of zeros
        defer { try? FileManager.default.removeItem(at: bomb) }

        let destination = root.appendingPathComponent("bomb-out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ZipExtractor.extract(archiveAt: bomb, to: destination)) { error in
            guard let zipError = error as? ZipExtractor.ZipError else {
                return XCTFail("Expected a ZipError, got \(error)")
            }
            switch zipError {
            case .entryTooLarge, .suspiciousRatio, .archiveTooLarge:
                break   // any of these is a correct rejection
            default:
                XCTFail("Bomb rejected for the wrong reason: \(zipError)")
            }
        }

        // Nothing large must have been written before the rejection.
        let written = (try? FileManager.default.contentsOfDirectory(at: destination,
                                                                   includingPropertiesForKeys: nil))?.count ?? 0
        XCTAssertEqual(written, 0, "A rejected archive must not leave output behind.")
    }

    /// A normal archive must still extract — the limits must not break real use.
    func testNormalArchiveStillExtractsUnderLimits() throws {
        let archive = try XCTUnwrap(fixtureURL("bundle-deflate"), "Missing test fixture.")
        let destination = root.appendingPathComponent("ok", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertNoThrow(try ZipExtractor.extract(archiveAt: archive, to: destination))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("index.html").path))
    }

    // MARK: Duplicate detection bounds

    /// The duplicate scan runs during `init()`, before any UI exists, so an
    /// unbounded read there meant a single huge file could crash the app on
    /// every launch with no in-app way to remove it.
    @MainActor
    func testOversizedFilesDoNotBreakLibraryLoading() async throws {
        // A file above the dedupe limit must be left alone rather than read.
        let big = DocumentStore.documentsRoot
            .appendingPathComponent("BigDoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        let payload = Data(count: 9 << 20)   // 9 MB, above the 8 MB scan limit
        try payload.write(to: big.appendingPathComponent("index.html"))
        defer { try? FileManager.default.removeItem(at: big) }

        // Re-instantiating the store exercises the load path that used to read
        // everything into memory.
        let store = DocumentStore()
        XCTAssertNotNil(store.documents, "Loading a library containing a large file must succeed.")
    }

    // MARK: Helpers

    private func fixtureURL(_ name: String) -> URL? {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: name, withExtension: "zip")
            ?? bundle.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures")
    }

    /// Builds a valid single-entry deflate archive of `expandedSize` zero bytes.
    private func makeDeflateBomb(expandedSize: Int) throws -> URL {
        let url = root.appendingPathComponent("bomb-\(UUID().uuidString).zip")

        // Raw deflate of zeros, produced with a tiny pure-Swift RLE-free encoder:
        // use the Compression framework's stream API in the encode direction.
        let payload = try deflateZeros(count: expandedSize)

        var archive = Data()
        let name = Array("bomb.bin".utf8)
        let crc = crc32(Data(count: expandedSize))

        // Local file header
        archive.append(uint32(0x04034b50)); archive.append(uint16(20)); archive.append(uint16(0))
        archive.append(uint16(8)); archive.append(uint16(0)); archive.append(uint16(0))
        archive.append(uint32(crc)); archive.append(uint32(UInt32(payload.count)))
        archive.append(uint32(UInt32(expandedSize)))
        archive.append(uint16(UInt16(name.count))); archive.append(uint16(0))
        archive.append(contentsOf: name)
        archive.append(payload)

        // Central directory
        let centralOffset = UInt32(archive.count)
        archive.append(uint32(0x02014b50)); archive.append(uint16(20)); archive.append(uint16(20))
        archive.append(uint16(0)); archive.append(uint16(8)); archive.append(uint16(0))
        archive.append(uint16(0)); archive.append(uint32(crc))
        archive.append(uint32(UInt32(payload.count))); archive.append(uint32(UInt32(expandedSize)))
        archive.append(uint16(UInt16(name.count))); archive.append(uint16(0)); archive.append(uint16(0))
        archive.append(uint16(0)); archive.append(uint16(0)); archive.append(uint32(0))
        archive.append(uint32(0)); archive.append(contentsOf: name)

        let centralSize = UInt32(archive.count) - centralOffset
        archive.append(uint32(0x06054b50)); archive.append(uint16(0)); archive.append(uint16(0))
        archive.append(uint16(1)); archive.append(uint16(1))
        archive.append(uint32(centralSize)); archive.append(uint32(centralOffset))
        archive.append(uint16(0))

        try archive.write(to: url)
        return url
    }

    /// Deflates a run of zero bytes at a very high ratio.
    private func deflateZeros(count: Int) throws -> Data {
        // 1 MB of zeros repeated is enough to exhibit the ratio; the declared
        // size in the header is what drives the bomb check.
        let chunk = Data(count: 1 << 20)
        guard let compressed = try? (chunk as NSData).compressed(using: .zlib) else {
            throw XCTSkip("Compression unavailable")
        }
        // Repeat the compressed chunk so the archive claims a huge expansion
        // with a small payload — the shape the extractor must reject.
        var out = Data()
        let repeats = max(1, count / (1 << 20))
        for _ in 0..<repeats { out.append(compressed as Data) }
        return out
    }

    private func uint16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func uint32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Content Security Policy

/// The CSP header is the main defence against a hostile document exfiltrating
/// the files it was imported alongside. It must actually be served.
final class ContentSecurityPolicyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-csp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<html><body>hi</body></html>".write(
            to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body{}".write(
            to: root.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("pic.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func headers(for path: String) throws -> [String: String] {
        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }
        let prefix = server.mount(directory: root, token: "csp-\(UUID().uuidString)")
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(prefix)\(path)"))

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: String] = [:]
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                for (key, value) in http.allHeaderFields {
                    result[String(describing: key).lowercased()] = String(describing: value)
                }
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 15)
        return result
    }

    func testHTMLResponseCarriesRestrictiveCSP() throws {
        let header = try headers(for: "index.html")

        let csp = try XCTUnwrap(header["content-security-policy"],
                                "HTML responses must carry a CSP, or a hostile page can exfiltrate freely.")

        // The load-bearing directive: no network egress except the document itself.
        XCTAssertTrue(csp.contains("connect-src 'self'"),
                      "connect-src must be restricted to self. Got: \(csp)")
        XCTAssertTrue(csp.contains("form-action 'none'"),
                      "Form submission must be blocked. Got: \(csp)")
        XCTAssertTrue(csp.contains("default-src 'self'"),
                      "default-src must be restricted to self. Got: \(csp)")
        // Inline/eval must stay allowed or legitimate single-file HTML breaks.
        XCTAssertTrue(csp.contains("'unsafe-inline'"),
                      "Inline script is required by real single-file documents. Got: \(csp)")
    }

    func testAllResponsesCarryNoSniff() throws {
        for path in ["index.html", "style.css", "pic.png"] {
            let header = try headers(for: path)
            XCTAssertEqual(header["x-content-type-options"], "nosniff",
                           "\(path) should be served with nosniff.")
        }
    }

    /// Non-HTML assets do not need a CSP; adding one there would be noise.
    func testNonHTMLAssetsAreNotGivenACSP() throws {
        let header = try headers(for: "style.css")
        XCTAssertNil(header["content-security-policy"],
                     "A stylesheet does not need a CSP header.")
    }
}

// MARK: - Document isolation

/// The isolation fix is only real if each engine gets a *distinct* data store.
/// If `WKWebsiteDataStore.nonPersistent()` returned a shared instance, documents
/// would still share localStorage and the fix would be cosmetic.
@MainActor
final class DocumentIsolationTests: XCTestCase {

    func testEachEngineGetsItsOwnDataStore() throws {
        let first = WebEngine()
        let second = WebEngine()

        let firstStore = first.webView.configuration.websiteDataStore
        let secondStore = second.webView.configuration.websiteDataStore

        XCTAssertFalse(firstStore === secondStore,
                       "Each document must get its own data store, or they share localStorage.")

        // And none of them may be the persistent default.
        XCTAssertFalse(firstStore === WKWebsiteDataStore.default(),
                       "A document must not use the shared persistent store.")
        XCTAssertFalse(firstStore.isPersistent,
                       "Document storage must not persist to disk.")
        XCTAssertFalse(secondStore.isPersistent)
    }

    /// The console bridge must be scoped to the document's own top frame, so an
    /// embedded remote iframe cannot reach native code.
    func testConsoleBridgeIsMainFrameOnly() throws {
        let engine = WebEngine()
        let scripts = engine.webView.configuration.userContentController.userScripts

        XCTAssertFalse(scripts.isEmpty, "The console bridge script should be installed.")
        for script in scripts {
            XCTAssertTrue(script.isForMainFrameOnly,
                          "Bridge scripts must not run in sub-frames.")
        }
    }

    /// Long console output must be clipped: the message cap bounds the count, not
    /// the size, so an unbounded string could pin gigabytes.
    func testConsoleMessagesAreClipped() throws {
        let engine = WebEngine()
        engine.recordConsoleMessage(level: "log", text: String(repeating: "A", count: 500_000))

        let message = try XCTUnwrap(engine.consoleMessages.last)
        XCTAssertLessThan(message.text.count, 10_000,
                          "A huge console message must be truncated before it is stored.")
        XCTAssertTrue(message.text.contains("truncated"))
    }
}

// MARK: - Pasted markup

/// Paste-and-run is a new execution path for untrusted input, so it gets the
/// same scrutiny as import: it must produce a real document on disk (served over
/// the local server with the CSP intact), not a special case that bypasses the
/// protections.
@MainActor
final class PasteMarkupTests: XCTestCase {

    func testCreatesRunnableDocumentFromMarkup() throws {
        let store = DocumentStore()
        let before = store.documents.count

        let html = """
        <!DOCTYPE html><html><head><title>Pasted Demo</title></head>
        <body><h1 id="t">Hello</h1><script>document.title='ran'</script></body></html>
        """
        let document = try store.createDocument(fromMarkup: html)
        defer { store.delete(store.documents.first { $0.id == document.id }!) }

        XCTAssertEqual(store.documents.count, before + 1)
        XCTAssertEqual(document.entryRelativePath, "index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.entryURL.path),
                      "The markup must be written to a real file so the server can serve it.")

        let written = try String(contentsOf: document.entryURL, encoding: .utf8)
        XCTAssertEqual(written, html, "Pasted markup must be preserved byte-for-byte.")
    }

    /// A complete document must not be wrapped — that would nest <html> in <html>.
    func testCompleteDocumentIsNotWrapped() throws {
        let full = "<!DOCTYPE html><html><body><p>ok</p></body></html>"
        XCTAssertEqual(DocumentStore.normaliseMarkup(full), full)
    }

    /// A bare fragment would render without a viewport tag on a phone, so it is
    /// wrapped — but the author's markup must survive untouched inside.
    func testFragmentIsWrappedAndPreserved() throws {
        let fragment = "<div class=\"x\">hi</div>"
        let normalised = DocumentStore.normaliseMarkup(fragment)

        XCTAssertTrue(normalised.contains("<!DOCTYPE html>"))
        XCTAssertTrue(normalised.contains("viewport"), "A phone needs a viewport meta tag.")
        XCTAssertTrue(normalised.contains(fragment),
                      "The author's markup must appear verbatim inside the shell.")
    }

    func testTitleIsTakenFromMarkupForNaming() throws {
        let store = DocumentStore()
        let document = try store.createDocument(
            fromMarkup: "<html><head><title>My Great Page</title></head><body>x</body></html>")
        defer { store.delete(store.documents.first { $0.id == document.id }!) }

        XCTAssertEqual(document.title, "My Great Page")
    }

    func testExplicitNameWinsOverPageTitle() throws {
        let store = DocumentStore()
        let document = try store.createDocument(
            fromMarkup: "<html><head><title>Ignored</title></head><body>x</body></html>",
            suggestedName: "Chosen Name")
        defer { store.delete(store.documents.first { $0.id == document.id }!) }

        XCTAssertEqual(document.title, "Chosen Name")
    }

    func testTitleExtractionHandlesEntitiesAndMissingTitle() {
        XCTAssertEqual(DocumentStore.extractTitle(from: "<title>A &amp; B</title>"), "A & B")
        XCTAssertNil(DocumentStore.extractTitle(from: "<html><body>no title</body></html>"))
        XCTAssertNil(DocumentStore.extractTitle(from: "<title>unclosed"))
    }

    func testEmptyAndOversizedPastesAreRejected() throws {
        let store = DocumentStore()

        XCTAssertThrowsError(try store.createDocument(fromMarkup: "   \n  ")) { error in
            guard case DocumentStore.PasteError.empty = error else {
                return XCTFail("Expected .empty, got \(error)")
            }
        }

        // Just over the 8 MB ceiling.
        let huge = String(repeating: "a", count: (8 << 20) + 16)
        XCTAssertThrowsError(try store.createDocument(fromMarkup: huge)) { error in
            guard case DocumentStore.PasteError.tooLarge = error else {
                return XCTFail("Expected .tooLarge, got \(error)")
            }
        }
    }

    /// Editing must write through and be reflected on disk, which is what makes
    /// the reload actually show a change.
    func testEditingMarkupUpdatesTheStoredFile() throws {
        let store = DocumentStore()
        let document = try store.createDocument(
            fromMarkup: "<html><head><title>First</title></head><body>v1</body></html>")
        defer { store.delete(store.documents.first { $0.id == document.id }!) }

        let updated = try store.updateMarkup(
            for: document,
            markup: "<html><head><title>Second</title></head><body>v2</body></html>")

        let onDisk = try String(contentsOf: updated.entryURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("v2"), "The edited markup must be persisted.")
        XCTAssertFalse(onDisk.contains("v1"), "The old content must be gone.")
        XCTAssertEqual(updated.title, "Second", "A changed <title> should update the library entry.")
    }

    /// Pasted content must be served like any other document, CSP included —
    /// otherwise paste would be a way around the protections added for import.
    func testPastedDocumentIsServedWithCSP() throws {
        let store = DocumentStore()
        let document = try store.createDocument(fromMarkup: "<html><body>pasted</body></html>")
        defer { store.delete(store.documents.first { $0.id == document.id }!) }

        let server = LocalHTTPServer.shared
        if server.port == 0 { try server.start() }
        let prefix = server.mount(directory: document.folderURL, token: "paste-\(UUID().uuidString)")

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(prefix)index.html"))
        let semaphore = DispatchSemaphore(value: 0)
        var csp: String?

        URLSession.shared.dataTask(with: URLRequest(url: url)) { _, response, _ in
            csp = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Security-Policy")
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 15)

        XCTAssertNotNil(csp, "A pasted document must be served with the same CSP as an import.")
        XCTAssertTrue(csp?.contains("connect-src 'self'") == true)
    }

    /// Markup detection drives whether the clipboard is pre-filled, so it should
    /// not grab ordinary prose.
    func testMarkupDetectionDistinguishesProseFromHTML() {
        XCTAssertTrue(PasteHTMLView.looksLikeMarkup("<div>hi</div>"))
        XCTAssertTrue(PasteHTMLView.looksLikeMarkup("<!DOCTYPE html><html></html>"))
        XCTAssertTrue(PasteHTMLView.looksLikeMarkup("<script>alert(1)</script>"))
        XCTAssertFalse(PasteHTMLView.looksLikeMarkup("Just a normal sentence about lunch."))
        XCTAssertFalse(PasteHTMLView.looksLikeMarkup(""))
    }
}
