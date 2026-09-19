import SwiftUI
import WebKit

/// Per-page controls and document details.
struct PageSettingsView: View {

    @ObservedObject var engine: WebEngine
    let document: Document

    @Environment(\.dismiss) private var dismiss

    @AppStorage("com.pagepocket.textZoom") private var textZoom: Double = 1.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text("\(Int(textZoom * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $textZoom, in: 0.6...2.2, step: 0.1) {
                            Text("Text Size")
                        } onEditingChanged: { editing in
                            // Apply when the user lets go, so the page does not
                            // reflow on every tick of the slider.
                            if !editing { applyTextZoom() }
                        }
                    }
                }

                Section("Document") {
                    LabeledContent("Title", value: document.displayTitle)
                    LabeledContent("Imported from", value: document.originalFileName)
                    LabeledContent("Contents", value: document.contentSummary)
                    LabeledContent("Entry file", value: document.entryRelativePath)
                    if let imported = document.importedAt as Date? {
                        LabeledContent("Imported") {
                            Text(imported, format: .dateTime.day().month().year().hour().minute())
                        }
                    }
                }

                if let baseURL = engine.documentBaseURL {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Served locally from")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(baseURL.absoluteString)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button {
                            UIPasteboard.general.string = baseURL.absoluteString
                        } label: {
                            Label("Copy URL", systemImage: "doc.on.doc")
                        }
                    } header: {
                        Text("Local Server")
                    } footer: {
                        Text("PagePocket serves this document over a loopback-only HTTP address so relative links, fetch() and ES modules work exactly as they do on the web. Nothing is reachable from other devices.")
                    }
                }

                Section("Storage") {
                    Button(role: .destructive) {
                        clearWebsiteData()
                    } label: {
                        Label("Clear Cookies & Local Storage", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Page Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { applyTextZoom() }
        }
    }

    /// Sets the page's base font size via a CSS override on `documentElement`.
    private func applyTextZoom() {
        let percent = Int(textZoom * 100)
        Task {
            _ = await engine.evaluate("""
            (function () {
              document.documentElement.style.webkitTextSizeAdjust = '\(percent)%';
            })();
            """)
        }
    }

    private func clearWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            store.removeData(ofTypes: types, for: records) {
                // Reload so the page comes back in a clean state.
                engine.hardReload()
            }
        }
    }
}
