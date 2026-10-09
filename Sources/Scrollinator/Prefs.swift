import AppKit

enum ScrollMode: String, CaseIterable, Identifiable {
    case voice, continuous

    var id: String { rawValue }
    var label: String {
        switch self {
        case .voice: return "Voice activated"
        case .continuous: return "Constant speed"
        }
    }
}

/// Typed access to UserDefaults. SettingsView binds to the same keys via @AppStorage.
enum Pref {
    enum Key {
        static let fontSize = "fontSize"
        static let textColor = "textColor"
        static let speed = "wordsPerMinute"
        static let scrollMode = "scrollMode"
        static let micSensitivity = "micSensitivity"
        static let countdown = "countdown"
        static let hideFromCapture = "hideFromCapture"
        static let followWords = "followWords"
        static let recordSessions = "recordSessions"
        static let recordingFolder = "recordingFolder"
        static let recordingFolderBookmark = "recordingFolderBookmark"
        /// A script ID from the library, or empty for the built-in practice script.
        static let testDriveScript = "testDriveScript"
        static let prompterWidth = "prompterWidth"
        static let prompterHeight = "prompterHeight"
    }

    enum Default {
        static let fontSize: Double = 30
        static let textColor = "#FFFFFF"
        static let speed: Double = 170
        static let scrollMode = ScrollMode.voice.rawValue
        static let micSensitivity: Double = 0.5
        static let countdown = 3
        static let hideFromCapture = true
        static let followWords = true
        static let recordSessions = false
        static let prompterWidth: Double = 460
        static let prompterHeight: Double = 190
    }

    /// Scroll speed is in spoken words per minute.
    static let speedRange: ClosedRange<Double> = 60...300
    static let speedStep: Double = 1

    static func register() {
        // Before registering defaults, which would make every key look already set.
        migrateFromTeleprompter()
        UserDefaults.standard.register(defaults: [
            Key.fontSize: Default.fontSize,
            Key.textColor: Default.textColor,
            Key.speed: Default.speed,
            Key.scrollMode: Default.scrollMode,
            Key.micSensitivity: Default.micSensitivity,
            Key.countdown: Default.countdown,
            Key.hideFromCapture: Default.hideFromCapture,
            Key.followWords: Default.followWords,
            Key.recordSessions: Default.recordSessions,
            Key.prompterWidth: Default.prompterWidth,
            Key.prompterHeight: Default.prompterHeight,
        ])
    }

    /// Brings settings over once from before the app was renamed. The App Store sandbox can't
    /// read another app's settings, so there this quietly finds nothing.
    private static func migrateFromTeleprompter() {
        let done = "migratedTeleprompterSettings"
        guard !d.bool(forKey: done), let old = UserDefaults(suiteName: "com.teleprompter.app") else { return }
        let keys = [
            Key.fontSize, Key.textColor, Key.speed, Key.scrollMode, Key.micSensitivity, Key.countdown,
            Key.hideFromCapture, Key.followWords, Key.recordSessions, Key.prompterWidth, Key.prompterHeight,
        ]
        for key in keys where d.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { d.set(value, forKey: key) }
        }
        d.set(true, forKey: done)
    }

    private static var d: UserDefaults { .standard }

    static var fontSize: CGFloat { CGFloat(d.double(forKey: Key.fontSize)) }
    static var textColor: NSColor { NSColor(hex: d.string(forKey: Key.textColor) ?? "") ?? .white }
    static var scrollMode: ScrollMode { ScrollMode(rawValue: d.string(forKey: Key.scrollMode) ?? "") ?? .voice }
    static var micSensitivity: Double { d.double(forKey: Key.micSensitivity) }
    static var countdown: Int { d.integer(forKey: Key.countdown) }
    static var hideFromCapture: Bool { d.bool(forKey: Key.hideFromCapture) }
    /// Voice mode only: follow the spoken words with speech recognition, not just the voice level.
    static var followWords: Bool { d.bool(forKey: Key.followWords) }
    /// Save a recording of the microphone for each prompter session.
    static var recordSessions: Bool { d.bool(forKey: Key.recordSessions) }

    /// Where recordings go, for display. `SessionRecorder` opens it with sandbox access.
    @MainActor static var recordingFolder: URL {
        d.string(forKey: Key.recordingFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? SessionRecorder.defaultFolder
    }

    /// A folder the user picked. The security-scoped bookmark keeps the App Store sandbox's
    /// permission to write there across launches; the path is for display.
    static var recordingFolderBookmark: Data? { d.data(forKey: Key.recordingFolderBookmark) }

    static func setRecordingFolder(_ url: URL) {
        d.set(url.path, forKey: Key.recordingFolder)
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        d.set(bookmark, forKey: Key.recordingFolderBookmark)
    }

    static var speed: Double {
        get { d.double(forKey: Key.speed) }
        set { d.set(min(max(newValue, speedRange.lowerBound), speedRange.upperBound), forKey: Key.speed) }
    }

    static var prompterSize: NSSize {
        get { NSSize(width: d.double(forKey: Key.prompterWidth), height: d.double(forKey: Key.prompterHeight)) }
        set {
            d.set(Double(newValue.width), forKey: Key.prompterWidth)
            d.set(Double(newValue.height), forKey: Key.prompterHeight)
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return Pref.Default.textColor }
        return String(
            format: "#%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded())
        )
    }
}
