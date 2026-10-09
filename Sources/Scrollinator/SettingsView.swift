import SwiftUI

/// Settings window: one tab per area, each with its own icon, beside the artwork and credits.
struct SettingsView: View {
    var body: some View {
        TabView {
            WithCredits { PrompterSettings() }
                .tabItem { Label("Prompter", systemImage: "text.viewfinder") }
            WithCredits { ScrollingSettings() }
                .tabItem { Label("Scrolling", systemImage: "scroll") }
            WithCredits { MicrophoneSettings() }
                .tabItem { Label("Microphone", systemImage: "mic") }
            WithCredits { RecordingSettings() }
                .tabItem { Label("Recording", systemImage: "record.circle") }
            WithCredits { ShortcutSettings() }
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
    }
}

/// Every tab shares the credits panel on the left and the same size, so the window holds still.
struct WithCredits<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            CreditsPanel().frame(width: 250)
            content.frame(width: 520)
        }
        .frame(height: 500)
    }
}

/// The app's artwork with credits for its creator.
private struct CreditsPanel: View {
    private static let x = URL(string: "https://x.com/chadalderson")!
    private static let barbless = URL(string: "https://barbless.co")!
    private static let repo = URL(string: "https://github.com/chadalderson/scrollinator")!
    /// The poster's red, for links.
    private static let red = Color(red: 1, green: 0.36, blue: 0.33)

    /// The full artwork the build bundles from Resources/AppIcon.png; the app icon otherwise.
    private var artwork: NSImage { NSImage(named: "Artwork") ?? NSApp.applicationIconImage }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Made by").font(.caption).foregroundStyle(.secondary)
                    Text("Chad Alderson").font(.title3.weight(.semibold))
                }
                Link(destination: Self.x) {
                    Label("Follow @chadalderson on X", systemImage: "at")
                }
                .foregroundStyle(Self.red)
                Link(destination: Self.barbless) {
                    Label("Creator of Barbless.co", systemImage: "arrow.up.right.square")
                }
                .foregroundStyle(Self.red)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(version) · free and open source")
                    Link("github.com/chadalderson/scrollinator", destination: Self.repo)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Prompter

struct PrompterSettings: View {
    @AppStorage(Pref.Key.fontSize) private var fontSize = Pref.Default.fontSize
    @AppStorage(Pref.Key.textColor) private var textColorHex = Pref.Default.textColor
    @AppStorage(Pref.Key.countdown) private var countdown = Pref.Default.countdown
    @AppStorage(Pref.Key.hideFromCapture) private var hideFromCapture = Pref.Default.hideFromCapture

    private var textColor: Color { Color(nsColor: NSColor(hex: textColorHex) ?? .white) }

    var body: some View {
        Form {
            Section {
                PrompterPreview(fontSize: fontSize, color: textColor)
                    .listRowInsets(EdgeInsets())
            }
            Section("Text") {
                LabeledContent("Size") {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: rounded($fontSize), in: 16...72)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        Text("\(Int(fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                LabeledContent("Color") {
                    ColorSwatches(selection: $textColorHex)
                }
            }
            Section("Behavior") {
                Picker("Countdown before starting", selection: $countdown) {
                    Text("Off").tag(0)
                    ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle(isOn: $hideFromCapture) {
                    Text("Hide from screen sharing")
                    Text("Viewers and screenshots won't see the prompter; only you will.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Pastel text colors that stay easy to read on the black prompter.
private struct ColorSwatches: View {
    @Binding var selection: String

    private static let swatches: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"), ("Red", "#FF9E9E"), ("Orange", "#FFC79E"), ("Yellow", "#FFF09E"),
        ("Green", "#A4F0C5"), ("Blue", "#A3D2FF"), ("Purple", "#CDB4FF"), ("Pink", "#FFB3DE"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.swatches, id: \.hex) { swatch in
                let selected = swatch.hex.caseInsensitiveCompare(selection) == .orderedSame
                Button {
                    selection = swatch.hex
                } label: {
                    Circle()
                        .fill(Color(nsColor: NSColor(hex: swatch.hex) ?? .white))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.25)))
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A miniature prompter showing the chosen size and color.
private struct PrompterPreview: View {
    var fontSize: Double
    var color: Color

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16)
                .fill(.black)
            Text("Good morning, everyone, and thanks for joining.")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(2)
                .minimumScaleFactor(0.4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
        }
        .frame(height: 104)
        .padding(12)
    }
}

// MARK: - Scrolling

struct ScrollingSettings: View {
    @AppStorage(Pref.Key.scrollMode) private var scrollMode = Pref.Default.scrollMode
    @AppStorage(Pref.Key.speed) private var speed = Pref.Default.speed
    @AppStorage(Pref.Key.followWords) private var followWords = Pref.Default.followWords
    @ObservedObject private var follower = SpeechFollower.shared

    private var isVoiceMode: Bool { scrollMode == ScrollMode.voice.rawValue }

    var body: some View {
        Form {
            Section("Mode") {
                HStack(alignment: .top, spacing: 12) {
                    ModeTile(
                        icon: "waveform", title: "Voice activated", caption: "Moves while you talk, stops when you pause",
                        selected: isVoiceMode
                    ) { scrollMode = ScrollMode.voice.rawValue }
                    ModeTile(
                        icon: "speedometer", title: "Constant speed", caption: "Moves steadily, no microphone needed",
                        selected: !isVoiceMode
                    ) { scrollMode = ScrollMode.continuous.rawValue }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
            }
            if isVoiceMode {
                Section {
                    Toggle(isOn: $followWords) {
                        Text("Follow my words")
                        Text("Recognizes what you say, on this Mac, and keeps the text on your place at your natural pace.")
                    }
                    FollowStatusRow(status: follower.status, enabled: followWords)
                }
            }
            Section {
                LabeledContent(isVoiceMode && followWords ? "Speed when not following" : "Speed") {
                    HStack(spacing: 10) {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(value: rounded($speed), in: Pref.speedRange)
                        Image(systemName: "hare").foregroundStyle(.secondary)
                        Text("\(Int(speed)) wpm").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                    }
                }
            } footer: {
                if isVoiceMode && followWords {
                    Text("While following your words the prompter shows your measured pace instead.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModeTile: View {
    var icon: String
    var title: String
    var caption: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title).font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Explains what Follow my words is doing, or what's stopping it.
private struct FollowStatusRow: View {
    var status: SpeechFollower.Status
    var enabled: Bool

    var body: some View {
        if enabled {
            switch status {
            case .denied:
                Notice(icon: "exclamationmark.triangle.fill", tint: .orange,
                       text: "Speech recognition is off for The Scrollinator.",
                       button: "Open Privacy Settings",
                       url: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            case .dictationOff:
                Notice(icon: "exclamationmark.triangle.fill", tint: .orange,
                       text: "Turn on Dictation to follow your words on this version of macOS.",
                       button: "Open Keyboard Settings",
                       url: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
            case .unavailable:
                Notice(icon: "info.circle.fill", tint: .secondary,
                       text: "This Mac can't recognize speech on-device, so the prompter uses your set speed.")
            case .preparing:
                Notice(icon: "arrow.down.circle.fill", tint: .secondary,
                       text: "Downloading the speech model for first use…")
            case .following:
                Notice(icon: "circle.fill", tint: .green, text: "Following your words now.")
            case .listening, .off:
                Notice(icon: "circle.fill", tint: .secondary,
                       text: "A dot on the prompter turns green while it has your place.")
            }
        }
    }
}

private struct Notice: View {
    var icon: String
    var tint: Color
    var text: String
    var button: String?
    var url: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .imageScale(icon == "circle.fill" ? .small : .medium)
            Text(text).foregroundStyle(.secondary)
            Spacer()
            if let button, let url, let link = URL(string: url) {
                Button(button) { NSWorkspace.shared.open(link) }
            }
        }
        .font(.callout)
    }
}

// MARK: - Microphone

struct MicrophoneSettings: View {
    @AppStorage(Pref.Key.micSensitivity) private var sensitivity = Pref.Default.micSensitivity
    @AppStorage(Pref.Key.scrollMode) private var scrollMode = Pref.Default.scrollMode
    @AppStorage(Pref.Key.recordSessions) private var recordSessions = Pref.Default.recordSessions
    @ObservedObject private var voice = VoiceDetector.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Input level")
                        Spacer()
                        SpeakingBadge(speaking: voice.isSpeaking)
                    }
                    LevelMeter(level: voice.level, threshold: voice.threshold, speaking: voice.isSpeaking)
                    Text("Talk normally: the bar turns green when your voice counts as speech. The marker sits just above your room's background noise.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        Text("Low").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $sensitivity, in: 0...1)
                        Text("High").font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Sensitivity")
                    Text("Raise it if quiet words are missed; lower it if noise moves the text.")
                }
            }
            if voice.permissionDenied {
                Section {
                    Notice(icon: "exclamationmark.triangle.fill", tint: .orange,
                           text: "Microphone access is off for The Scrollinator.",
                           button: "Open Privacy Settings",
                           url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
            } else if let error = voice.errorMessage {
                Section {
                    Notice(icon: "exclamationmark.triangle.fill", tint: .orange, text: error)
                }
            }
            if scrollMode != ScrollMode.voice.rawValue && !recordSessions {
                Section {
                    Notice(icon: "info.circle.fill", tint: .secondary,
                           text: "Constant speed doesn't use the microphone; this is just a level check.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { voice.acquire("settings") }
        .onDisappear { voice.release("settings") }
    }
}

private struct SpeakingBadge: View {
    var speaking: Bool

    var body: some View {
        Label(speaking ? "Speaking" : "Quiet", systemImage: speaking ? "waveform" : "waveform.slash")
            .font(.caption.weight(.semibold))
            .foregroundStyle(speaking ? Color.green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(speaking ? Color.green.opacity(0.15) : Color.primary.opacity(0.06)))
            .animation(.easeOut(duration: 0.15), value: speaking)
    }
}

private struct LevelMeter: View {
    var level: Float
    var threshold: Float
    var speaking: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(speaking ? Color.green : Color.secondary)
                    .frame(width: max(10, geo.size.width * CGFloat(level)))
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 2, height: 16)
                    .offset(x: geo.size.width * CGFloat(threshold) - 1)
            }
            .frame(height: 16)
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.08), value: level)
    }
}

// MARK: - Recording

struct RecordingSettings: View {
    @AppStorage(Pref.Key.recordSessions) private var recordSessions = Pref.Default.recordSessions
    @AppStorage(Pref.Key.recordingFolder) private var recordingFolderPath = SessionRecorder.defaultFolder.path
    @ObservedObject private var recorder = SessionRecorder.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $recordSessions) {
                    Text("Record my voice while prompting")
                    Text("Saves an \(format) for each session, from Start Prompting until you close the prompter.")
                }
            }
            Section("Save recordings to") {
                HStack(spacing: 10) {
                    Image(nsImage: folderIcon)
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((recordingFolderPath as NSString).lastPathComponent)
                        Text(((recordingFolderPath as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder", systemImage: "folder", action: openFolder)
                        .labelStyle(.iconOnly)
                        .help("Show in Finder")
                    Button("Choose…", action: chooseFolder)
                }
            }
            if let error = recorder.lastError {
                Section {
                    Notice(icon: "exclamationmark.triangle.fill", tint: .orange, text: error)
                }
            } else if let saved = recorder.lastSaved {
                Section("Last recording") {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(.secondary)
                        Text(saved.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                    }
                }
            }
            Section {
                Notice(icon: "record.circle", tint: .red,
                       text: "A red dot and timer show on the prompter while it records. Mono \(format), 128 kbps.")
            }
        }
        .formStyle(.grouped)
    }

    /// The folder's own icon once it exists; a plain folder until the first recording creates it.
    private var folderIcon: NSImage {
        FileManager.default.fileExists(atPath: recordingFolderPath)
            ? NSWorkspace.shared.icon(forFile: recordingFolderPath)
            : NSWorkspace.shared.icon(for: .folder)
    }

    private func openFolder() {
        SessionRecorder.revealFolder()
    }

    private var format: String { SessionRecorder.fileExtension.uppercased() }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where The Scrollinator saves recordings."
        panel.directoryURL = URL(fileURLWithPath: recordingFolderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            Pref.setRecordingFolder(url)
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(HotKeys.descriptions, id: \.keys) { item in
                    LabeledContent(item.action) {
                        KeyCaps(keys: item.keys)
                    }
                }
            } footer: {
                Text("These work from any app, even while the prompter is in the background.")
            }
        }
        .formStyle(.grouped)
    }
}

/// "⌃⌥Space" drawn as separate keys.
private struct KeyCaps: View {
    var keys: String

    private var caps: [String] {
        let modifiers = keys.prefix { "⌃⌥⇧⌘".contains($0) }.map(String.init)
        let rest = String(keys.dropFirst(modifiers.count))
        return modifiers + (rest.isEmpty ? [] : [rest])
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, cap.count > 1 ? 6 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.08))
                            .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
    }
}

/// Slider values snapped to whole numbers without step tick marks.
private func rounded(_ value: Binding<Double>) -> Binding<Double> {
    Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() })
}
