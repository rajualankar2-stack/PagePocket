import Foundation

/// The App Group shared between the app and its Share Extension.
///
/// The extension cannot write into the app's own sandbox, so anything shared to
/// PagePocket is staged here first. The app drains this on launch and whenever it
/// returns to the foreground.
///
/// This file is compiled into **both** targets. Keeping the identifier in one
/// place means the two can never silently disagree — a mismatch would produce a
/// container that one process can see and the other cannot.
enum SharedInbox {

    /// Must match `com.apple.security.application-groups` in both entitlement files.
    static let appGroupIdentifier = "group.com.pagepocket.app"

    /// The shared container, or `nil` if the App Group entitlement is missing.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Where shared items wait to be imported.
    static var inboxURL: URL? {
        containerURL?.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Returns the inbox directory, creating it if needed.
    @discardableResult
    static func ensureInbox() throws -> URL {
        guard let inbox = inboxURL else {
            throw InboxError.appGroupUnavailable
        }
        if !FileManager.default.fileExists(atPath: inbox.path) {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        return inbox
    }

    /// Copies a file or folder into the inbox, under a collision-free name.
    ///
    /// - Returns: The location inside the inbox.
    @discardableResult
    static func stage(at source: URL, preferredName: String? = nil) throws -> URL {
        let inbox = try ensureInbox()
        let fileManager = FileManager.default

        let baseName = preferredName ?? source.lastPathComponent
        let destination = uniqueURL(in: inbox, preferredName: baseName, fileManager: fileManager)

        // A security-scoped URL from the share sheet must be opened before reading.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    /// Appends " 2", " 3", … until the name is free.
    private static func uniqueURL(in directory: URL, preferredName: String, fileManager: FileManager) -> URL {
        let candidate = directory.appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: next.path) { return next }
        }

        // Practically unreachable; fall back to a unique suffix.
        let fallback = ext.isEmpty ? "\(stem) \(UUID().uuidString)" : "\(stem) \(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(fallback)
    }

    enum InboxError: LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "The shared container is unavailable. Check that the App Group entitlement is present."
            }
        }
    }
}
