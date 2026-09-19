import Compression
import Foundation

/// Minimal ZIP reader, enough to unpack an HTML bundle a user saved from a
/// chat app or a website.
///
/// Foundation has no archive API on iOS, so this parses the central directory
/// directly and inflates entries with the Compression framework. It supports
/// the two compression methods that matter in practice (stored and deflate)
/// and refuses anything else rather than producing corrupt output.
enum ZipExtractor {

    enum ZipError: LocalizedError {
        case notAZip
        case truncated
        case unsupportedCompression(UInt16)
        case unsafePath(String)
        case inflateFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: return "the file is not a ZIP archive"
            case .truncated: return "the archive appears to be incomplete"
            case .unsupportedCompression(let method): return "unsupported compression method \(method)"
            case .unsafePath(let path): return "the archive contains an unsafe path (\(path))"
            case .inflateFailed(let name): return "“\(name)” could not be decompressed"
            }
        }
    }

    /// Extracts every entry into `destination`, creating subdirectories as needed.
    static func extract(archiveAt archiveURL: URL, to destination: URL) throws {
        let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let entries = try readCentralDirectory(in: data)

        let fileManager = FileManager.default

        for entry in entries {
            // Skip macOS resource forks and directory markers.
            guard !entry.name.hasSuffix("/") else { continue }
            if entry.name.hasPrefix("__MACOSX/") || entry.name.contains("/__MACOSX/") { continue }
            if entry.name.hasSuffix(".DS_Store") { continue }

            let relative = try sanitize(entry.name)
            // Reject absolute paths and traversal before touching the disk.
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                throw ZipError.unsafePath(entry.name)
            }

            let outputURL = destination.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let payload = try compressedPayload(for: entry, in: data)
            let contents: Data

            switch entry.compressionMethod {
            case 0:
                contents = payload
            case 8:
                contents = try inflate(payload, expectedSize: Int(entry.uncompressedSize), name: entry.name)
            default:
                throw ZipError.unsupportedCompression(entry.compressionMethod)
            }

            try contents.write(to: outputURL, options: .atomic)
        }
    }

    // MARK: - Central directory

    private struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: UInt32
        let localHeaderOffset: Int
    }

    /// Locates and parses the End Of Central Directory record and the entries it points to.
    private static func readCentralDirectory(in data: Data) throws -> [Entry] {
        // EOCD signature 0x06054b50, searched backwards because of the comment field.
        let minimumEOCDSize = 22
        guard data.count >= minimumEOCDSize else { throw ZipError.notAZip }

        let searchLimit = min(data.count, 65_536 + minimumEOCDSize)
        var eocdOffset: Int?

        var index = data.count - minimumEOCDSize
        let lowerBound = data.count - searchLimit
        while index >= lowerBound {
            if data[index] == 0x50, data[index + 1] == 0x4b,
               data[index + 2] == 0x05, data[index + 3] == 0x06 {
                eocdOffset = index
                break
            }
            index -= 1
        }

        guard let eocd = eocdOffset else { throw ZipError.notAZip }

        let entryCount = Int(readUInt16(data, eocd + 10))
        let centralDirectoryOffset = Int(readUInt32(data, eocd + 16))

        guard centralDirectoryOffset >= 0, centralDirectoryOffset < data.count else {
            throw ZipError.truncated
        }

        var entries: [Entry] = []
        var cursor = centralDirectoryOffset

        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count else { throw ZipError.truncated }
            // Central file header signature 0x02014b50
            guard data[cursor] == 0x50, data[cursor + 1] == 0x4b,
                  data[cursor + 2] == 0x01, data[cursor + 3] == 0x02 else {
                break
            }

            let method = readUInt16(data, cursor + 10)
            let compressedSize = Int(readUInt32(data, cursor + 20))
            let uncompressedSize = readUInt32(data, cursor + 24)
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let localOffset = Int(readUInt32(data, cursor + 42))

            guard cursor + 46 + nameLength <= data.count else { throw ZipError.truncated }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let name = String(decoding: nameData, as: UTF8.self)

            entries.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))

            cursor += 46 + nameLength + extraLength + commentLength
        }

        return entries
    }

    /// Reads an entry's bytes, honouring the local header's own name/extra lengths.
    private static func compressedPayload(for entry: Entry, in data: Data) throws -> Data {
        let offset = entry.localHeaderOffset
        guard offset + 30 <= data.count else { throw ZipError.truncated }
        // Local file header signature 0x04034b50
        guard data[offset] == 0x50, data[offset + 1] == 0x4b,
              data[offset + 2] == 0x03, data[offset + 3] == 0x04 else {
            throw ZipError.truncated
        }

        // The local header's name/extra lengths can differ from the central one.
        let nameLength = Int(readUInt16(data, offset + 26))
        let extraLength = Int(readUInt16(data, offset + 28))
        let start = offset + 30 + nameLength + extraLength

        guard start + entry.compressedSize <= data.count else { throw ZipError.truncated }
        return data.subdata(in: start..<(start + entry.compressedSize))
    }

    // MARK: - Decompression

    /// Raw DEFLATE inflate via the Compression framework.
    private static func inflate(_ payload: Data, expectedSize: Int, name: String) throws -> Data {
        guard !payload.isEmpty else { return Data() }
        guard expectedSize > 0 else { return Data() }

        var output = Data(count: expectedSize)
        let written: Int = output.withUnsafeMutableBytes { outputBuffer -> Int in
            guard let outputPointer = outputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return payload.withUnsafeBytes { inputBuffer -> Int in
                guard let inputPointer = inputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // COMPRESSION_ZLIB in Apple's API means raw DEFLATE, which is what ZIP stores.
                return compression_decode_buffer(
                    outputPointer, expectedSize,
                    inputPointer, payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { throw ZipError.inflateFailed(name) }
        if written < expectedSize {
            output = output.prefix(written)
        }
        return output
    }

    // MARK: - Byte helpers

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func sanitize(_ name: String) throws -> String {
        // Normalise separators and drop leading "./".
        var cleaned = name.replacingOccurrences(of: "\\", with: "/")
        while cleaned.hasPrefix("./") { cleaned.removeFirst(2) }
        while cleaned.hasPrefix("/") { cleaned.removeFirst() }
        return cleaned
    }
}
