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
        importSharedItems()
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

        tidyLegacyTitles()
        removeDuplicates()
    }

    /// Collapses documents that are byte-for-byte the same file.
    ///
    /// Older builds had no duplicate check, so opening the same file twice left
    /// two identical entries in the library. Removes the later one and deletes
    /// its folder, keeping whichever copy came first.
    ///
    /// Deliberately conservative: this runs during `init()`, so anything it
    /// loads is loaded before the UI exists. A single huge entry file would
    /// therefore OOM the app on every launch with no way to delete it from
    /// inside the app. Files above `dedupeSizeLimit` are left alone, and the
    /// comparison is skipped entirely unless names and sizes already match.
    private func removeDuplicates() {
        /// Only files this small are considered; a large video or archive is
        /// never a duplicate worth risking a launch crash over.
        let dedupeSizeLimit = 8 << 20   // 8 MB

        var seenKeys = Set<String>()
        var survivors: [Document] = []
        var removed = 0

        for document in documents {
            let values = try? document.entryURL.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = values?.fileSize ?? 0

            guard fileSize > 0, fileSize <= dedupeSizeLimit else {
                survivors.append(document)
                continue
            }

            // Cheap discriminator first: only read bytes when name AND size
            // already agree, which is rare.
            let cheapKey = "\(document.originalFileName)|\(fileSize)"
            let alreadyCandidate = survivors.contains { candidate in
                guard let candidateSize = try? candidate.entryURL
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
                return candidate.originalFileName == document.originalFileName
                    && candidateSize == fileSize
            }

            guard alreadyCandidate else {
                seenKeys.insert(cheapKey)
                survivors.append(document)
                continue
            }

            // Full byte comparison, with a hard cap so a pathological file
            // cannot exhaust memory here.
            guard let incoming = try? Data(contentsOf: document.entryURL, options: .mappedIfSafe),
                  incoming.count <= dedupeSizeLimit else {
                survivors.append(document)
                continue
            }

            let duplicateOf = survivors.first { candidate in
                guard candidate.originalFileName == document.originalFileName else { return false }
                guard let existing = try? Data(contentsOf: candidate.entryURL, options: .mappedIfSafe) else {
                    return false
                }
                return existing == incoming
            }

            if duplicateOf != nil {
                try? fileManager.removeItem(at: document.folderURL)
                removed += 1
            } else {
                seenKeys.insert(cheapKey)
                survivors.append(document)
            }
        }

        if removed > 0 {
            documents = survivors
            save()
            Log.library.notice("Removed \(removed) duplicate document(s) from the library.")
        }
    }

    /// Re-tidies titles saved by an older build.
    ///
    /// Titles used to be the raw filename, so a library created before the
    /// friendly-title change would keep showing "s4hana-cvi-explainer.html"
    /// forever. Records whose display name nothing else depends on are safe to
    /// rename, so the fix applies to existing documents rather than only new ones.
    private func tidyLegacyTitles() {
        var changed = false

        for index in documents.indices {
            let current = documents[index].title
            let tidied = Self.friendlyTitle(from: current)
            if tidied != current, !tidied.isEmpty {
                documents[index].title = tidied
                changed = true
            }
        }

        if changed { save() }
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

        // Opening the same file twice (a second tap in the Files app, or a
        // re-share) should not pile up identical library entries. If a document
        // with the same name and byte-for-byte content already exists, hand that
        // one back instead of making another copy.
        if let existing = existingDocument(matching: source) {
            Log.library.notice("“\(source.lastPathComponent, privacy: .public)” is already in the library; reusing it.")
            return existing
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

    /// Finds an existing document whose entry file is identical to `source`.
    ///
    /// Bounded on purpose: the source is untrusted input, so a multi-gigabyte
    /// file must not be read into memory just to decide whether it is a
    /// duplicate. Anything above the limit is simply treated as new.
    private func existingDocument(matching source: URL) -> Document? {
        let limit = 8 << 20   // 8 MB

        guard let sourceSize = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              sourceSize > 0, sourceSize <= limit else { return nil }

        for document in documents {
            guard document.originalFileName == source.lastPathComponent else { continue }
            guard let existingSize = try? document.entryURL
                .resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  existingSize == sourceSize else { continue }

            guard let incoming = try? Data(contentsOf: source, options: .mappedIfSafe),
                  let existing = try? Data(contentsOf: document.entryURL, options: .mappedIfSafe) else {
                continue
            }
            if existing == incoming { return document }
        }
        return nil
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

        // A single-file import keeps the file's own name, which tends to be
        // machine-generated (e.g. "deepseek_html_20260918_82c086.html"). Strip
        // the extension and tidy the separators so the library reads well.
        title = Self.friendlyTitle(from: title)

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
    ///
    /// `sourceName` is the original filename when it is known (for a loose file
    /// that was imported into a generated folder, the folder name is a UUID and
    /// useless as a display name).
    private func registerExistingFolder(_ folder: URL, entry: URL, sourceName: String? = nil) throws -> Document {
        let stats = Self.measure(folder: folder)

        let rawName: String
        if let sourceName {
            rawName = sourceName
        } else {
            rawName = entry.deletingPathExtension().lastPathComponent.lowercased() == "index"
                ? folder.lastPathComponent
                : entry.lastPathComponent
        }

        let document = Document(
            title: Self.friendlyTitle(from: rawName),
            storedFolderName: folder.lastPathComponent,
            entryRelativePath: Self.relativePath(of: entry, in: folder),
            originalFileName: rawName,
            contentSummary: stats
        )
        documents.insert(document, at: 0)
        save()
        return document
    }

    // MARK: - Files shared from other apps

    /// Imports anything the Share Extension staged in the shared App Group.
    ///
    /// The extension runs in its own process and cannot touch the app's sandbox,
    /// so it copies shared files into a shared container and this drains them.
    /// Items are moved (not copied) so a failure part-way cannot leave the same
    /// file to be imported twice on the next launch.
    func importSharedItems() {
        guard let inbox = SharedInbox.inboxURL,
              fileManager.fileExists(atPath: inbox.path) else { return }

        let staged: [URL]
        do {
            staged = try fileManager.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.library.error("Could not read the shared inbox: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !staged.isEmpty else { return }

        for item in staged {
            Task { @MainActor in
                do {
                    let document = try await importItem(at: item)
                    // Only remove once the copy into the library has succeeded.
                    try? fileManager.removeItem(at: item)
                    Log.library.notice("Imported shared item “\(document.displayTitle, privacy: .public)”.")
                } catch {
                    // Quarantine instead of leaving it to fail on every launch.
                    // A file that cannot be read at all would otherwise retry
                    // forever and log an error each time.
                    Log.library.error("Could not import shared item \(item.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    quarantine(item)
                }
            }
        }
    }

    /// Moves an unimportable inbox item aside so it stops being retried.
    ///
    /// It is kept (not deleted) under `Failed/` so the file the user shared is
    /// never silently thrown away.
    private func quarantine(_ item: URL) {
        guard let container = SharedInbox.containerURL else { return }
        let failedDir = container.appendingPathComponent("Failed", isDirectory: true)

        do {
            if !fileManager.fileExists(atPath: failedDir.path) {
                try fileManager.createDirectory(at: failedDir, withIntermediateDirectories: true)
            }
            let destination = failedDir.appendingPathComponent(item.lastPathComponent)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: item, to: destination)
            Log.library.notice("Moved \(item.lastPathComponent, privacy: .public) to Failed; it will not be retried.")
        } catch {
            // If it cannot be moved, remove it: retrying a permanently broken
            // item on every launch is worse than dropping it.
            try? fileManager.removeItem(at: item)
        }
    }

    /// Turns a raw filename into something readable in the library.
    ///
    /// "s4hana-cvi-explainer.html" → "S4hana Cvi Explainer"; a machine-generated
    /// name like "deepseek_html_20260918_82c086" is left mostly intact because
    /// guessing a better one is not possible, but separators are cleaned up.
    nonisolated static func friendlyTitle(from rawName: String) -> String {
        var name = rawName

        // Drop a trailing extension if one survived.
        if let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) <= 6 {
            name = String(name[name.startIndex..<dot])
        }

        // Normalise separators to spaces.
        name = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        // Collapse runs of whitespace.
        name = name.split(separator: " ").joined(separator: " ")

        guard !name.isEmpty else { return rawName }

        // Title-case only when the name looks like ordinary words. A name with
        // long digit runs (a timestamp or hash) is left alone, since title-casing
        // it would only make it harder to recognise.
        let hasLongDigitRun = name.range(of: "[0-9]{6,}", options: .regularExpression) != nil
        if !hasLongDigitRun {
            name = name
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }

        return name
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
