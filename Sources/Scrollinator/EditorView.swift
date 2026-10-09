import SwiftUI

/// The Scripts window, styled like Settings: black, with the poster's red for highlights.
struct EditorView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var selection: Script.ID?

    var body: some View {
        HStack(spacing: 0) {
            ScriptSidebar(selection: $selection, delete: delete)
                .frame(width: 240)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                if let id = selection, let script = store.binding(for: id) {
                    ScriptDetailView(script: script, delete: { delete(id) })
                        .id(id)
                } else {
                    ContentUnavailableView(
                        "No Script Selected",
                        systemImage: "text.alignleft",
                        description: Text("Select a script or create a new one.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .tint(Theme.red)
        .environment(\.colorScheme, .dark)
        .background(BlackWindow())
        .onAppear {
            if selection == nil { selection = store.scripts.first?.id }
        }
    }

    private func delete(_ id: Script.ID) {
        store.delete(id)
        if selection == id { selection = store.scripts.first?.id }
    }
}

private struct ScriptSidebar: View {
    @EnvironmentObject private var store: ScriptStore
    @Binding var selection: Script.ID?
    var delete: (Script.ID) -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // The app icon itself, rounded square and shadow included, as it looks in the Dock.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 46, height: 46)
                    .padding(-4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("THE SCROLLINATOR")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.red)
                    Text("Scripts").font(.headline)
                }
                Spacer()
                Button {
                    selection = store.add().id
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.red.opacity(0.16)))
                        .foregroundStyle(Theme.red)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n")
                .help("New script (⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.scripts) { script in
                        ScriptRow(script: script, selected: script.id == selection)
                            .onTapGesture { selection = script.id }
                            .contextMenu {
                                Button("Delete", role: .destructive) { delete(script.id) }
                            }
                    }
                }
                .padding(.horizontal, 8)
            }

            Rectangle().fill(Theme.line).frame(height: 1)
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.card)
        }
    }
}

private struct ScriptRow: View {
    var script: Script
    var selected: Bool

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(selected ? Theme.red : .clear)
                .frame(width: 3)
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(script.title.isEmpty ? "Untitled" : script.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color(white: 0.85))
                    .lineLimit(1)
                Text(script.updatedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 9)
            .padding(.vertical, 7)
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.red.opacity(0.14) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ScriptDetailView: View {
    @Binding var script: Script
    var delete: () -> Void
    @EnvironmentObject private var prompter: PrompterController

    private var isEmpty: Bool { script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TextField("Title", text: $script.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .bold))
                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete this script")
                Button {
                    prompter.start(script)
                } label: {
                    Label("Start Prompting", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
            TextEditor(text: $script.body)
                .font(.system(size: 15))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Text("\(script.wordCount) words · about \(readingTime)")
                Spacer()
                Text("⌘↩ to start")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Theme.card)
        }
    }

    /// At a typical speaking pace of 150 words per minute.
    private var readingTime: String {
        let seconds = Int((Double(script.wordCount) / 150 * 60).rounded())
        return seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min \(seconds % 60) sec"
    }
}
