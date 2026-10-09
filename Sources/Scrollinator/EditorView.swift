import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var selection: Script.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.scripts) { script in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(script.title.isEmpty ? "Untitled" : script.title)
                            .lineLimit(1)
                        Text(script.updatedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(script.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { delete(script.id) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                ToolbarItem {
                    Button {
                        selection = store.add().id
                    } label: {
                        Label("New Script", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n")
                }
            }
        } detail: {
            if let id = selection, let script = store.binding(for: id) {
                ScriptDetailView(script: script)
                    .id(id)
            } else {
                ContentUnavailableView(
                    "No Script Selected",
                    systemImage: "text.alignleft",
                    description: Text("Select a script or create a new one.")
                )
            }
        }
        .onDeleteCommand {
            if let id = selection { delete(id) }
        }
        .onAppear {
            if selection == nil { selection = store.scripts.first?.id }
        }
    }

    private func delete(_ id: Script.ID) {
        store.delete(id)
        if selection == id { selection = store.scripts.first?.id }
    }
}

private struct ScriptDetailView: View {
    @Binding var script: Script
    @EnvironmentObject private var prompter: PrompterController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $script.title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
            Divider()
            TextEditor(text: $script.body)
                .font(.system(size: 15))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
            Divider()
            HStack {
                Text("\(script.wordCount) words · about \(readingTime)")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    prompter.start(script)
                } label: {
                    Label("Start Prompting", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// At a typical speaking pace of 150 words per minute.
    private var readingTime: String {
        let seconds = Int((Double(script.wordCount) / 150 * 60).rounded())
        return seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min \(seconds % 60) sec"
    }
}
