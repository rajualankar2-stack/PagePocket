import Foundation

/// Reads and writes documents inside the app's own Documents directory.
///
/// All user content lives in `Documents/`, which is exposed to the Files app
/// (see `UIFileSharingEnabled`), so power users can drop folders in directly.
@MainActor
final class DocumentStore: ObservableObject {

    @Published private(set) var documents: [Document] = []

    /// Errors surfaced to the UI as an alert.
    @Published var lastError: String?

    // MARK: - Locations

    /// `Documents/` — user-visible content root.
    ///
    /// Non-isolated because `Document` (a plain value type) builds file URLs
    /// from it, and those are not main-actor bound.
    nonisolated static var documentsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// `Library/Application Support/PagePocket/` — private metadata.
    nonisolated private static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PagePocket", isDirectory: true)
    }

    private var indexURL: URL { Self.supportRoot.appendingPathComponent("library.json") }

    private let fileManager = FileManager.default

    // MARK: - Lifecycle

    init() {
        createDirectoriesIfNeeded()
        load()
        seedSampleDocumentsIfFirstLaunch()
        adoptLooseFiles()
    }

    private func createDirectoriesIfNeeded() {
        for url in [Self.documentsRoot, Self.supportRoot] {
            if !fileManager.fileExists(atPath: url.path) {
                try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else {
            documents = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        documents = (try? decoder.decode([Document].self, from: data)) ?? []

        // Drop entries whose files vanished (e.g. deleted from the Files app).
        documents.removeAll { !fileManager.fileExists(atPath: $0.entryURL.path) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(documents) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Queries

    func document(withID id: Document.ID) -> Document? {
        documents.first { $0.id == id }
    }

    func markOpened(_ id: Document.ID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].lastOpenedAt = Date()
        save()
    }

    // MARK: - Importing

    /// Imports files or folders chosen in the document picker.
    ///
    /// Each pick is handled independently so one bad item does not abort the
    /// rest of a multi-selection.
    func importPicks(_ urls: [URL]) async {
        var failures: [String] = []

        for url in urls {
            // Files chosen with `asCopy: false` arrive security-scoped.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            do {
                _ = try await importItem(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        }
    }

    /// Imports one filesystem item and returns the created document.
    @discardableResult
    func importItem(at url: URL) async throws -> Document {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }

        // A ZIP is unpacked and then treated as a folder.
        if !isDirectory.boolValue, url.pathExtension.lowercased() == "zip" {
            return try await importZip(at: url)
        }

        if isDirectory.boolValue {
            return try importFolder(at: url)
        }
        return try importSingleFile(at: url)
    }

    /// Copies a whole folder, preserving structure so relative assets resolve.
    private func importFolder(at source: URL) throws -> Document {
        let folderName = UUID().uuidString
        let destination = Self.documentsRoot.appendingPathComponent(folderName, isDirectory: true)

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try copyContents(of: source, into: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        guard let entry = try Self.findEntryFile(in: destination) else {
            try? fileManager.removeItem(at: destination)
            throw ImportError.noHTMLEntry(source.lastPathComponent)
        }
        return try register(folder: destination, folderName: folderName,
                            entry: entry, originalName: source.lastPathComponent)
    }

    /// Copies a folder's children, skipping symlinks and nested junk.
    private func copyContents(of source: URL, into destination: URL) throws {
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Symlinks can escape the imported tree; skip them.
            if values.isSymbolicLink == true { continue }

            let target = destination.appendingPathComponent(child.lastPathComponent)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                try copyContents(of: child, into: target)
            } else {
                try fileManager.copyItem(at: child, to: target)
            }
        }
    }

    /// Copies a single HTML file. Assets next to it are not reachable without
    /// folder access, so the UI steers users toward importing folders.
    private func importSingleFile(at source: URL) throws -> Document {
        let ext = source.pathExtension.lowercased()
        let htmlExtensions: Set<String> = ["html", "htm", "xhtml", "svg"]
        guard htmlExtensions.contains(ext) else {
            throw ImportError.unsupportedType(source.pathExtension)
        }

        let folderName = UUID().uuidString
        let destination = Self.documentsRoot.appendingPathComponent(folderName, isDirectory: true)

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        // Normalise to index.html so the folder has a predictable entry point.
        let target = destination.appendingPathComponent("index." + (ext == "xhtml" ? "xhtml" : "html"))
        do {
            try fileManager.copyItem(at: source, to: target)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return try register(folder: destination, folderName: folderName,
                            entry: target, originalName: source.lastPathComponent)
    }

    /// Unpacks a ZIP archive into a fresh folder and imports the result.
    private func importZip(at source: URL) async throws -> Document {
        let folderName = UUID().uuidString
        let destination = Self.documentsRoot.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try ZipExtractor.extract(archiveAt: source, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        // Archives often contain a single wrapper folder; unwrap it so the
        // entry file is not one level deeper than the user expects.
        let effectiveRoot = try unwrapSingleWrapperFolder(in: destination)

        guard let entry = try Self.findEntryFile(in: effectiveRoot) else {
            try? fileManager.removeItem(at: destination)
            throw ImportError.noHTMLEntry(source.lastPathComponent)
        }

        let relative = Self.relativePath(of: entry, in: destination)
        return try register(folder: destination, folderName: folderName,
                            entry: entry, originalName: source.lastPathComponent,
                            entryRelativePath: relative)
    }

    /// If a folder contains exactly one subfolder and no files, return that subfolder.
    private func unwrapSingleWrapperFolder(in root: URL) throws -> URL {
        var current = root
        for _ in 0..<3 {
            let children = try fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            // macOS zips often carry a __MACOSX sidecar; ignore it when counting.
            let meaningful = children.filter { $0.lastPathComponent != "__MACOSX" }
            guard meaningful.count == 1 else { break }

            let only = meaningful[0]
            let isDirectory = (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory == true else { break }
            current = only
        }
        return current
    }

    /// Builds a `Document` record, writes it to the index and reports on content.
    private func register(
        folder: URL,
        folderName: String,
        entry: URL,
        originalName: String,
        entryRelativePath: String? = nil
    ) throws -> Document {
        let relative = entryRelativePath ?? Self.relativePath(of: entry, in: folder)
        let stats = Self.measure(folder: folder)

        var title = entry.deletingPathExtension().lastPathComponent
        if title.lowercased() == "index", let parent = entry.pathComponents.dropLast().last,
           parent != folderName {
            title = parent
        }
        if title.isEmpty || title.lowercased() == "index" {
            title = originalName
        }

        let document = Document(
            title: title,
            storedFolderName: folderName,
            entryRelativePath: relative,
            originalFileName: originalName,
            contentSummary: stats
        )

        documents.insert(document, at: 0)
        save()
        return document
    }

    // MARK: - Mutating

    func delete(_ document: Document) {
        try? fileManager.removeItem(at: document.folderURL)
        documents.removeAll { $0.id == document.id }
        save()
    }

    func rename(_ document: Document, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index].title = trimmed
        save()
    }

    // MARK: - Sample content

    /// Copies the bundled demo documents in once, so a fresh install has
    /// something to show and something to prove the renderer works.
    private func seedSampleDocumentsIfFirstLaunch() {
        let flagKey = "com.pagepocket.didSeedSamples"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        UserDefaults.standard.set(true, forKey: flagKey)

        guard let samplesRoot = Bundle.main.url(forResource: "Samples", withExtension: nil) else { return }

        let folders = (try? fileManager.contentsOfDirectory(
            at: samplesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for sample in folders {
            let isDirectory = (try? sample.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory == true else { continue }

            let folderName = UUID().uuidString
            let destination = Self.documentsRoot.appendingPathComponent(folderName, isDirectory: true)
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                try copyContents(of: sample, into: destination)
                if let entry = try Self.findEntryFile(in: destination) {
                    _ = try register(folder: destination, folderName: folderName,
                                     entry: entry, originalName: sample.lastPathComponent + ".html")
                }
            } catch {
                try? fileManager.removeItem(at: destination)
            }
        }
    }

    // MARK: - Adopting files added outside the app

    /// Imports anything sitting loose in `Documents/` that the library does not
    /// know about yet.
    ///
    /// The Documents folder is user-visible in the Files app
    /// (`UIFileSharingEnabled`), so people can drop `.html` files and folders in
    /// directly — or sync them via iCloud Drive. Without this, those files would
    /// sit there invisibly, because the library is driven by its own index.
    ///
    /// Items already owned by a document are skipped, so this only ever picks up
    /// genuinely new arrivals.
    func adoptLooseFiles() {
        let knownFolders = Set(documents.map(\.storedFolderName))
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: Self.documentsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.library.error("Could not scan Documents: \(error.localizedDescription, privacy: .public)")
            return
        }

        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Skip the folders this app already manages.
            if knownFolders.contains(item.lastPathComponent) { continue }
            // Skip the app's own metadata if it ever lands here.
            if item.lastPathComponent.hasPrefix(".") { continue }

            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let ext = item.pathExtension.lowercased()

            if isDirectory {
                // A dropped folder becomes a document in place — no copy needed,
                // since it already lives in our Documents directory.
                guard let entry = try? Self.findEntryFile(in: item),
                      let document = try? registerExistingFolder(item, entry: entry) else { continue }
                Log.library.notice("Adopted folder “\(document.displayTitle, privacy: .public)” from Documents.")
            } else if ["html", "htm", "xhtml", "zip"].contains(ext) {
                // A loose file is copied into its own document folder, then the
                // original is removed so it is not adopted again on next launch.
                Task { @MainActor in
                    do {
                        let document = try await importItem(at: item)
                        try? fileManager.removeItem(at: item)
                        Log.library.notice("Adopted file “\(document.displayTitle, privacy: .public)” from Documents.")
                    } catch {
                        Log.library.error("Could not adopt \(item.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Registers a folder that is already inside `Documents/` without copying it.
    private func registerExistingFolder(_ folder: URL, entry: URL) throws -> Document {
        let stats = Self.measure(folder: folder)
        var title = entry.deletingPathExtension().lastPathComponent
        if title.lowercased() == "index" { title = folder.lastPathComponent }

        let document = Document(
            title: title,
            storedFolderName: folder.lastPathComponent,
            entryRelativePath: Self.relativePath(of: entry, in: folder),
            originalFileName: folder.lastPathComponent,
            contentSummary: stats
        )
        documents.insert(document, at: 0)
        save()
        return document
    }

    // MARK: - Static helpers

    // These are pure filesystem helpers with no shared mutable state, so they
    // are deliberately nonisolated: the importer, the ZIP path and tests can all
    // call them from any context.

    /// Finds the file a folder should open by default.
    nonisolated static func findEntryFile(in folder: URL) throws -> URL? {
        let fm = FileManager.default
        var htmlFiles: [URL] = []

        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix("__MACOSX") { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "html" || ext == "htm" || ext == "xhtml" {
                htmlFiles.append(url)
            }
        }

        guard !htmlFiles.isEmpty else { return nil }

        // Preference order: shallowest index.html, then any index.*, then
        // the shallowest HTML file, then alphabetical.
        let sorted = htmlFiles.sorted { lhs, rhs in
            let lhsDepth = lhs.pathComponents.count
            let rhsDepth = rhs.pathComponents.count
            let lhsIsIndex = lhs.deletingPathExtension().lastPathComponent.lowercased() == "index"
            let rhsIsIndex = rhs.deletingPathExtension().lastPathComponent.lowercased() == "index"

            if lhsIsIndex != rhsIsIndex { return lhsIsIndex }
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.path < rhs.path
        }
        return sorted.first
    }

    nonisolated static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return url.lastPathComponent }
        var relative = String(filePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    /// "12 files · 240 KB"
    nonisolated static func measure(folder: URL) -> String {
        let fm = FileManager.default
        var fileCount = 0
        var totalBytes: Int64 = 0

        if let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                fileCount += 1
                totalBytes += Int64(values.fileSize ?? 0)
            }
        }

        let fileLabel = fileCount == 1 ? "1 file" : "\(fileCount) files"
        return "\(fileLabel) · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case unreadable(String)
        case noHTMLEntry(String)
        case unsupportedType(String)
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "“\(name)” could not be read. Try downloading it to this device first."
            case .noHTMLEntry(let name):
                return "“\(name)” contains no .html file to display."
            case .unsupportedType(let ext):
                return ext.isEmpty
                    ? "That file type isn’t supported. Choose an .html file or a folder."
                    : ".\(ext) files aren’t supported. Choose an .html file or a folder."
            case .zipFailed(let detail):
                return "That ZIP could not be opened: \(detail)"
            }
        }
    }
}
