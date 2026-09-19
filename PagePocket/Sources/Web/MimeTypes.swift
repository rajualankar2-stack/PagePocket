import Foundation

/// Maps file extensions to MIME types.
///
/// Correct content types matter more than they look: ES modules are rejected by
/// WebKit unless JavaScript is served as a JavaScript MIME type, and CSS/JSON
/// modules fail the same way.
enum MimeTypes {

    private static let table: [String: String] = [
        // Documents
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "xhtml": "application/xhtml+xml; charset=utf-8",
        "svg": "image/svg+xml",
        "xml": "application/xml; charset=utf-8",
        "txt": "text/plain; charset=utf-8",
        "md": "text/plain; charset=utf-8",
        "csv": "text/csv; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8",
        "pdf": "application/pdf",

        // Scripts — must be a JS MIME type or module loading fails.
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "cjs": "text/javascript; charset=utf-8",
        "jsx": "text/javascript; charset=utf-8",
        "ts": "text/javascript; charset=utf-8",

        // Styles
        "css": "text/css; charset=utf-8",

        // Images
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "bmp": "image/bmp",
        "ico": "image/x-icon",
        "heic": "image/heic",
        "tiff": "image/tiff",
        "tif": "image/tiff",

        // Fonts
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "eot": "application/vnd.ms-fontobject",

        // Media
        "mp4": "video/mp4",
        "m4v": "video/x-m4v",
        "mov": "video/quicktime",
        "webm": "video/webm",
        "ogv": "video/ogg",
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "wav": "audio/wav",
        "oga": "audio/ogg",
        "ogg": "audio/ogg",
        "flac": "audio/flac",
        "opus": "audio/opus",

        // Archives / other
        "zip": "application/zip",
        "wasm": "application/wasm",
        "glb": "model/gltf-binary",
        "gltf": "model/gltf+json",
        "usdz": "model/vnd.usdz+zip",
        "vtt": "text/vtt; charset=utf-8",
        "srt": "text/plain; charset=utf-8"
    ]

    /// Content type for a path, falling back to a neutral binary type.
    static func contentType(forPathExtension ext: String) -> String {
        table[ext.lowercased()] ?? "application/octet-stream"
    }

    static func contentType(for url: URL) -> String {
        contentType(forPathExtension: url.pathExtension)
    }

    /// Whether a response with this type should be compressed on the fly.
    static func isCompressible(_ contentType: String) -> Bool {
        contentType.hasPrefix("text/")
            || contentType.contains("javascript")
            || contentType.contains("json")
            || contentType.contains("xml")
            || contentType.contains("svg")
    }
}
