import SwiftUI

/// Paste (or edit) HTML and run it.
///
/// Used for two flows:
/// - **New**: paste markup from anywhere and run it as a document.
/// - **Edit**: reopen an existing document's source, change it, and re-run.
///
/// In both cases the markup becomes a real document folder served over the local
/// HTTP server, so it gets the same Content-Security-Policy, storage isolation
/// and navigation limits as an imported file.
struct PasteHTMLView: View {

    /// What the editor is being used for.
    enum Mode {
        case create
        case edit(Document)

        var navigationTitle: String {
            switch self {
            case .create: return "Paste HTML"
            case .edit: return "Edit HTML"
            }
        }

        var actionTitle: String {
            switch self {
            case .create: return "Run"
            case .edit: return "Save & Reload"
            }
        }
    }

    let mode: Mode

    /// Called with the document to show once the markup has been saved.
    var onRun: (Document) -> Void

    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var markup: String = ""
    @State private var name: String = ""
    @State private var errorMessage: String?
    @State private var didLoadExisting = false

    @FocusState private var editorFocused: Bool

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                nameField
                Divider()
                editor
                Divider()
                statusBar
            }
            .navigationTitle(mode.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(mode.actionTitle) { run() }
                        .fontWeight(.semibold)
                        .disabled(markup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                // The keyboard covers the editor on a phone; give a way to
                // dismiss it without losing the markup.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editorFocused = false }
                }
            }
            .alert("Couldn’t Run That", isPresented: errorBinding) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: loadExistingIfNeeded)
        }
    }

    // MARK: - Sections

    private var nameField: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat")
                .foregroundStyle(.secondary)
                .font(.footnote)

            TextField("Name (optional)", text: $name)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()

            if !isEditing {
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .disabled(UIPasteboard.general.hasStrings == false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $markup)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .accessibilityIdentifier("paste.editor")

            if markup.isEmpty {
                Text(placeholder)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: String {
        """
        <!DOCTYPE html>
        <html>
          <body>
            <h1>Hello</h1>
          </body>
        </html>

        Paste or type HTML, then tap \(mode.actionTitle).
        """
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: sizeWarning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.caption2)
                .foregroundStyle(sizeWarning ? .orange : .secondary)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(sizeWarning ? .orange : .secondary)

            Spacer()

            if editorFocused {
                Button("Done") { editorFocused = false }
                    .font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var sizeWarning: Bool {
        markup.utf8.count > 4 << 20
    }

    private var statusText: String {
        let bytes = markup.utf8.count
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)

        if bytes == 0 {
            return "Pasted markup runs as its own page, with the same protections as an imported file."
        }
        if sizeWarning {
            return "\(size) — large pastes are slow to run."
        }
        if !Self.looksLikeCompleteDocument(markup) {
            return "\(size) · fragment detected, will be wrapped in a page"
        }
        return "\(size) · runs as a normal page"
    }

    // MARK: - Actions

    private func loadExistingIfNeeded() {
        guard !didLoadExisting else { return }
        didLoadExisting = true

        // Start from the clipboard on a fresh paste, since that is almost always
        // what the user came here with.
        if case .create = mode {
            if UIPasteboard.general.hasStrings, let clipboard = UIPasteboard.general.string,
               Self.looksLikeMarkup(clipboard) {
                markup = clipboard
            }
            return
        }

        if case .edit(let document) = mode {
            name = document.displayTitle
            markup = (try? String(contentsOf: document.entryURL, encoding: .utf8)) ?? ""
        }
    }

    private func pasteFromClipboard() {
        guard let clipboard = UIPasteboard.general.string, !clipboard.isEmpty else { return }
        // Replace wholesale rather than insert at a caret the user cannot see.
        markup = clipboard
    }

    private func run() {
        do {
            let document: Document

            switch mode {
            case .create:
                document = try store.createDocument(fromMarkup: markup,
                                                    suggestedName: name.isEmpty ? nil : name)
            case .edit(let existing):
                document = try store.updateMarkup(for: existing, markup: markup,
                                                  newName: name.isEmpty ? nil : name)
            }

            onRun(document)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - Heuristics

    /// Whether pasted text looks like markup rather than prose.
    static func looksLikeMarkup(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("<html") || lowered.contains("<!doctype")
            || lowered.contains("<div") || lowered.contains("<body")
            || lowered.contains("<script") || lowered.contains("<style")
            || lowered.contains("<p>") || lowered.contains("<h1")
            || lowered.contains("<svg") || lowered.contains("<canvas")
    }

    static func looksLikeCompleteDocument(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("<html") || lowered.contains("<!doctype")
    }
}
