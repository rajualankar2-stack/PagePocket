import SwiftUI

/// Home screen: the user's imported documents plus the import action.
struct LibraryView: View {

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var store: DocumentStore

    @State private var isShowingPicker = false
    @State private var searchText = ""
    @State private var documentToDelete: Document?
    @State private var documentToRename: Document?
    @State private var renameText = ""

    /// Drives a programmatic push, used only by the automation hook below.
    @State private var autoOpenDocument: Document?

    var body: some View {
        NavigationStack {
            Group {
                if store.documents.isEmpty {
                    emptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("PagePocket")
            .searchable(text: $searchText, prompt: "Search documents")
            .toolbar { toolbarContent }
            .navigationDestination(item: $autoOpenDocument) { document in
                DocumentBrowserView(document: document)
            }
            .onAppear { performAutoOpenIfRequested() }
            // The Documents folder is visible in the Files app, so files can
            // arrive while the app is backgrounded. Re-scan when it comes back.
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.willEnterForegroundNotification)
            ) { _ in
                store.adoptLooseFiles()
            }
            .sheet(isPresented: $isShowingPicker) {
                DocumentPicker { urls in
                    Task { await store.importPicks(urls) }
                }
                .ignoresSafeArea()
            }
            .alert("Import Failed", isPresented: errorBinding) {
                Button("OK", role: .cancel) { store.lastError = nil }
            } message: {
                Text(store.lastError ?? "")
            }
            .alert("Rename Document", isPresented: renameBinding) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { documentToRename = nil }
                Button("Save") {
                    if let document = documentToRename {
                        store.rename(document, to: renameText)
                    }
                    documentToRename = nil
                }
            }
            .confirmationDialog(
                "Delete “\(documentToDelete?.displayTitle ?? "")”?",
                isPresented: deleteBinding,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let document = documentToDelete { store.delete(document) }
                    documentToDelete = nil
                }
                Button("Cancel", role: .cancel) { documentToDelete = nil }
            } message: {
                Text("This removes the document and all of its files from PagePocket.")
            }
        }
    }

    // MARK: - Content

    private var filteredDocuments: [Document] {
        guard !searchText.isEmpty else { return store.documents }
        return store.documents.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                || $0.originalFileName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var documentList: some View {
        List {
            if let serverError = appModel.serverError {
                Section {
                    Label(serverError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                ForEach(filteredDocuments) { document in
                    NavigationLink {
                        DocumentBrowserView(document: document)
                    } label: {
                        DocumentRow(document: document)
                    }
                    .contextMenu {
                        Button {
                            documentToRename = document
                            renameText = document.displayTitle
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            documentToDelete = document
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            documentToDelete = document
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("\(store.documents.count) document\(store.documents.count == 1 ? "" : "s")")
            } footer: {
                Text("Tip: import a **folder** rather than a lone file when a page needs its own CSS, JavaScript or images.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Documents", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Import an HTML file or a folder from the Files app to get started.")
        } actions: {
            Button {
                isShowingPicker = true
            } label: {
                Label("Import HTML", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingPicker = true
            } label: {
                Label("Import", systemImage: "plus")
            }
        }
    }

    // MARK: - Automation hook

    /// Opens a document automatically when launched with `-AutoOpenDocument <name>`.
    ///
    /// Debug-only. It exists so an automated test can drive the app straight to
    /// a rendered page (and screenshot it) without simulating taps through the
    /// file picker, which cannot be scripted.
    private func performAutoOpenIfRequested() {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let wanted = defaults.string(forKey: "AutoOpenDocument"), !wanted.isEmpty else { return }
        // Consume it so a normal relaunch behaves normally.
        defaults.removeObject(forKey: "AutoOpenDocument")

        guard let match = store.documents.first(where: {
            $0.displayTitle.localizedCaseInsensitiveContains(wanted)
                || $0.originalFileName.localizedCaseInsensitiveContains(wanted)
        }) else {
            Log.app.error("AutoOpenDocument: no document matching “\(wanted, privacy: .public)”")
            return
        }
        Log.app.notice("AutoOpenDocument: opening “\(match.displayTitle, privacy: .public)”")
        autoOpenDocument = match
        #endif
    }

    // MARK: - Bindings

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { documentToRename != nil },
            set: { if !$0 { documentToRename = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { documentToDelete != nil },
            set: { if !$0 { documentToDelete = nil } }
        )
    }
}

/// One row in the library list.
private struct DocumentRow: View {

    let document: Document

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconBackground)
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(document.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(document.contentSummary)
                    if let opened = document.lastOpenedAt {
                        Text("·")
                        Text(opened, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconBackground: some ShapeStyle {
        LinearGradient(
            colors: [Color(red: 0.36, green: 0.42, blue: 0.98),
                     Color(red: 0.55, green: 0.30, blue: 0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
