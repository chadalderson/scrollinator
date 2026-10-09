import Carbon.HIToolbox

/// System-wide shortcuts via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5450_524D), id: id) // 'TPRM'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            actions[id] = action
            refs.append(ref)
        } else {
            NSLog("Scrollinator: could not register hotkey \(keyCode) (status \(status)); another app may own it.")
        }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum HotKeys {
    static let modifiers = controlKey | optionKey

    /// Shown in Settings; keep in sync with registerDefaults().
    static let descriptions: [(keys: String, action: String)] = [
        ("⌃⌥Space", "Play / pause"),
        ("⌃⌥↑", "Jump back"),
        ("⌃⌥↓", "Jump forward"),
        ("⌃⌥=", "Faster"),
        ("⌃⌥−", "Slower"),
        ("⌃⌥R", "Restart from top"),
        ("⌃⌥H", "Show / hide prompter"),
    ]

    @MainActor
    static func registerDefaults() {
        let center = HotKeyCenter.shared
        let prompter = PrompterController.shared
        center.register(keyCode: kVK_Space, modifiers: modifiers) { prompter.togglePlayPause() }
        center.register(keyCode: kVK_UpArrow, modifiers: modifiers) { prompter.jump(lines: -2) }
        center.register(keyCode: kVK_DownArrow, modifiers: modifiers) { prompter.jump(lines: 2) }
        center.register(keyCode: kVK_ANSI_Equal, modifiers: modifiers) { prompter.changeSpeed(by: Pref.speedStep) }
        center.register(keyCode: kVK_ANSI_Minus, modifiers: modifiers) { prompter.changeSpeed(by: -Pref.speedStep) }
        center.register(keyCode: kVK_ANSI_R, modifiers: modifiers) { prompter.restart() }
        center.register(keyCode: kVK_ANSI_H, modifiers: modifiers) { prompter.toggleVisibility() }
    }
}
