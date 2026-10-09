import SwiftUI

@main
struct ScrollinatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ScriptStore.shared
    @StateObject private var prompter = PrompterController.shared

    init() {
        Pref.register()
    }

    var body: some Scene {
        Window("Scripts", id: "scripts") {
            EditorView()
                .environmentObject(store)
                .environmentObject(prompter)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandMenu("Prompter") {
                Button("Play / Pause") { prompter.togglePlayPause() }
                Button("Restart from Top") { prompter.restart() }
                Button("Show / Hide Prompter") { prompter.toggleVisibility() }
                Divider()
                Button("Faster") { prompter.changeSpeed(by: Pref.speedStep) }
                Button("Slower") { prompter.changeSpeed(by: -Pref.speedStep) }
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("The Scrollinator", systemImage: "text.viewfinder") {
            MenuBarContent()
                .environmentObject(prompter)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var prompter: PrompterController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(prompter.isVisible ? "Hide Prompter" : "Show Prompter") { prompter.toggleVisibility() }
        Button(prompter.isPlaying ? "Pause" : "Play") { prompter.togglePlayPause() }
        Button("Restart from Top") { prompter.restart() }
            .disabled(!prompter.isVisible)
        Divider()
        Button("Scripts…") {
            openWindow(id: "scripts")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Button("Open Recordings Folder") { SessionRecorder.revealFolder() }
        Divider()
        Button("Quit The Scrollinator") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeys.registerDefaults()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        SessionRecorder.shared.stop()
        ScriptStore.shared.save()
    }
}
