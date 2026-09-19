import Foundation
import os

/// App-wide loggers.
///
/// These go through `os.Logger` rather than `print` so the messages land in the
/// unified logging system. That makes them visible to Console.app, to
/// `log collect`, and to automated checks — `print` output only ever reaches
/// stdout and is lost the moment the app is launched any way other than
/// attached to a terminal.
enum Log {

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.pagepocket.app"

    /// Local server lifecycle: binding, mounts, request failures.
    static let server = Logger(subsystem: subsystem, category: "server")

    /// Document import, storage and library changes.
    static let library = Logger(subsystem: subsystem, category: "library")

    /// Web view navigation and page-level failures.
    static let web = Logger(subsystem: subsystem, category: "web")

    /// App lifecycle and automation hooks.
    static let app = Logger(subsystem: subsystem, category: "app")
}
