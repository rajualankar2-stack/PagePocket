import SwiftUI

/// Runs arbitrary JavaScript in the current page and shows the result.
///
/// Useful for inspecting state, poking at a generated app, or driving a UI that
/// has no other affordance.
struct ScriptRunnerView: View {

    @ObservedObject var engine: WebEngine
    @Environment(\.dismiss) private var dismiss

    @State private var script = ""
    @State private var history: [Entry] = []
    @State private var isRunning = false

    private struct Entry: Identifiable {
        let id = UUID()
        let script: String
        let result: String
        let isError: Bool
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editor
                Divider()
                results
            }
            .navigationTitle("JavaScript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await run() }
                    } label: {
                        if isRunning {
                            ProgressView()
                        } else {
                            Label("Run", systemImage: "play.fill")
                        }
                    }
                    .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Expression or statement")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)

            TextEditor(text: $script)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 110)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if script.isEmpty {
                        Text("document.title")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

            if !history.isEmpty {
                historyStrip
            }
        }
        .padding(.bottom, 10)
    }

    private var historyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(history.reversed()) { entry in
                    Button {
                        script = entry.script
                    } label: {
                        Text(entry.script)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if history.isEmpty {
                    Text("Results appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 30)
                }

                ForEach(history.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.script)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)

                        Text(entry.result)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(entry.isError ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(
                                (entry.isError ? Color.red.opacity(0.09) : Color.secondary.opacity(0.10)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                }
            }
            .padding()
        }
    }

    private func run() async {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isRunning = true
        let result = await engine.evaluate(trimmed)
        isRunning = false

        switch result {
        case .success(let value):
            history.append(Entry(script: trimmed, result: value, isError: false))
        case .failure(let error):
            history.append(Entry(script: trimmed, result: error.localizedDescription, isError: true))
        }
    }
}
