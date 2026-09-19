import Foundation

/// Abstraction over "somewhere a random file can be written", used by the
/// screenshot/share features.
enum TemporaryFiles {

    /// Writes `data` to a uniquely named file in the temporary directory.
    static func write(_ data: Data, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PagePocket", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let target = directory.appendingPathComponent(fileName)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// Removes stale items left behind by earlier runs.
    static func cleanUp() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PagePocket", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }
}
