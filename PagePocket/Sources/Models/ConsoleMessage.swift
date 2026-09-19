import Foundation

/// A single captured console message from the web view.
struct ConsoleMessage: Identifiable, Hashable {
    enum Level: String, Hashable {
        case log, info, warn, error, debug

        var symbolName: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .debug: return "ladybug.fill"
            default: return "text.alignleft"
            }
        }
    }

    let id = UUID()
    let level: Level
    let text: String
    let timestamp: Date
}

/// A runtime error surfaced by WebKit itself (navigation or JS exception).
struct PageIssue: Identifiable, Hashable {
    let id = UUID()
    let message: String
    let detail: String?
    let timestamp: Date
}
