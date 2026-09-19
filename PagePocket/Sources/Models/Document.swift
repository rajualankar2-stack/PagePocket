import Foundation

/// One HTML document the user has imported into PagePocket.
///
/// A document is a *self-contained folder*: the entry HTML file plus every
/// asset it needs (CSS, JS, images, data files). Keeping the whole tree
/// together is what makes relative paths and `fetch()` work once the folder is
/// served over HTTP.
struct Document: Identifiable, Codable, Hashable {

    let id: UUID

    /// Display name shown in the library, derived from the entry file.
    var title: String

    /// Folder name on disk inside the app's Documents directory.
    let storedFolderName: String

    /// Path of the entry HTML file, relative to the document folder.
    var entryRelativePath: String

    /// Original location the user imported from, for display only.
    var originalFileName: String

    var importedAt: Date
    var lastOpenedAt: Date?

    /// Bookmarks let the app remember a file the user opened in place from the
    /// Files app, so "Reload from source" can re-read it.
    var sourceBookmark: Data?

    /// Small description of what was imported, e.g. "12 files, 240 KB".
    var contentSummary: String

    init(
        id: UUID = UUID(),
        title: String,
        storedFolderName: String,
        entryRelativePath: String,
        originalFileName: String,
        importedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        sourceBookmark: Data? = nil,
        contentSummary: String
    ) {
        self.id = id
        self.title = title
        self.storedFolderName = storedFolderName
        self.entryRelativePath = entryRelativePath
        self.originalFileName = originalFileName
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
        self.sourceBookmark = sourceBookmark
        self.contentSummary = contentSummary
    }
}

extension Document {

    /// The folder that holds this document's files.
    var folderURL: URL {
        DocumentStore.documentsRoot.appendingPathComponent(storedFolderName, isDirectory: true)
    }

    /// The entry HTML file on disk.
    var entryURL: URL {
        folderURL.appendingPathComponent(entryRelativePath)
    }

    var displayTitle: String {
        title.isEmpty ? originalFileName : title
    }
}
