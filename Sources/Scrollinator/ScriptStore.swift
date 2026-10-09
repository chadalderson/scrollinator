import Foundation
import SwiftUI

struct Script: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var updatedAt = Date()

    var wordCount: Int { body.split { $0.isWhitespace || $0.isNewline }.count }
}

/// Scripts live in a single JSON file in Application Support. Nothing leaves the Mac.
@MainActor
final class ScriptStore: ObservableObject {
    static let shared = ScriptStore()

    @Published var scripts: [Script] = [] {
        didSet { scheduleSave() }
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Scrollinator", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("scripts.json")
        // Carry scripts over from before the app was renamed (outside the App Store sandbox only).
        let legacy = support.appendingPathComponent("Teleprompter/scripts.json")
        if !fm.fileExists(atPath: fileURL.path) && fm.fileExists(atPath: legacy.path) {
            try? fm.copyItem(at: legacy, to: fileURL)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? decoder.decode([Script].self, from: data) {
            scripts = saved
        } else {
            scripts = [Script.welcome]
            save()
        }
    }

    @discardableResult
    func add() -> Script {
        let script = Script(title: "Untitled Script", body: "")
        scripts.insert(script, at: 0)
        return script
    }

    func delete(_ id: Script.ID) {
        scripts.removeAll { $0.id == id }
    }

    func binding(for id: Script.ID) -> Binding<Script>? {
        guard let initial = scripts.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.scripts.first(where: { $0.id == id }) ?? initial },
            set: { newValue in
                guard let i = self.scripts.firstIndex(where: { $0.id == id }) else { return }
                var updated = newValue
                updated.updatedAt = Date()
                self.scripts[i] = updated
            }
        )
    }

    func save() {
        saveTask?.cancel()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(scripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
}

extension Script {
    static let welcome = Script(
        title: "Welcome",
        body: """
        Welcome to The Scrollinator. This text sits right under your camera, so you can read while keeping eye contact.

        In voice mode the text moves while you speak and stops when you pause. Try reading this paragraph out loud and watch the waveform at the bottom react to your voice.

        Hover over the prompter to pause it. Scroll with your trackpad to move around. Drag the prompter anywhere, and drag its bottom-right corner to resize it.

        Shortcuts work from any app:
        Control-Option-Space to play or pause.
        Control-Option-Up and Down to jump back or forward.
        Control-Option-Plus and Minus to change speed.
        Control-Option-R to restart, and Control-Option-H to hide or show the prompter.

        The prompter is hidden from screen sharing and screenshots, so only you can see it. Write your own scripts in the Scripts window, then press Start Prompting.
        """
    )
}
