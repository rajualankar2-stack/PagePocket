import SwiftUI

/// A devtools-style console for the current document.
///
/// Local HTML is often generated code, so surfacing JavaScript errors and
/// console output is the difference between "it's broken" and "line 42 is
/// missing a variable".
struct ConsoleView: View {

    @ObservedObject var engine: WebEngine
    @Environment(\.dismiss) private var dismiss

    @State private var filter: Filter = .all
    @State private var searchText = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all, errors, warnings, logs
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .errors: return "Errors"
            case .warnings: return "Warnings"
            case .logs: return "Logs"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredMessages.isEmpty && engine.issues.isEmpty {
                    ContentUnavailableView {
                        Label("Console is Empty", systemImage: "terminal")
                    } description: {
                        Text("Messages logged by the page appear here.")
                    }
                } else {
                    messageList
                }
            }
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Filter output")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(Filter.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Divider()
                        Button {
                            UIPasteboard.general.string = plainTextTranscript
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            engine.clearConsole()
                            engine.clearIssues()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    } label: {
                        Label("Options", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Content

    private var messageList: some View {
        List {
            if !engine.issues.isEmpty {
                Section("Page Errors") {
                    ForEach(engine.issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                            if let detail = issue.detail {
                                Text(detail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !filteredMessages.isEmpty {
                Section("Output") {
                    ForEach(filteredMessages) { message in
                        MessageRow(message: message)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var filteredMessages: [ConsoleMessage] {
        engine.consoleMessages.filter { message in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .errors: matchesFilter = message.level == .error
            case .warnings: matchesFilter = message.level == .warn
            case .logs: matchesFilter = message.level != .error && message.level != .warn
            }

            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            return message.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var plainTextTranscript: String {
        var lines: [String] = []
        for issue in engine.issues {
            lines.append("[error] \(issue.message)")
            if let detail = issue.detail { lines.append("        \(detail)") }
        }
        for message in engine.consoleMessages {
            lines.append("[\(message.level.rawValue)] \(message.text)")
        }
        return lines.joined(separator: "\n")
    }
}

/// One console line, with a suitable colour per level.
private struct MessageRow: View {

    let message: ConsoleMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.level.symbolName)
                .font(.caption2)
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 3)

            Text(message.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private var color: Color {
        switch message.level {
        case .error: return .red
        case .warn: return .orange
        case .debug: return .secondary
        default: return .primary
        }
    }
}
