import AppKit
import Combine

/// Owns the prompter panel and drives scrolling: a 60 Hz tick advances the text while playing,
/// unless the pointer is hovering, a countdown is running, or (in voice mode) the user is silent.
/// In voice mode with "follow my words" on, speech recognition keeps the text on the spoken words
/// and the speed follows the speaker's measured pace.
@MainActor
final class PrompterController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = PrompterController()

    @Published private(set) var isVisible = false
    @Published private(set) var isPlaying = false
    /// Reading a practice script from Settings; never recorded.
    @Published private(set) var isTestDriving = false

    private let voice = VoiceDetector.shared
    private let store = ScriptStore.shared
    private let follower = SpeechFollower.shared
    private let recorder = SessionRecorder.shared
    private var pacer = PaceFollower()
    private var panel: PrompterPanel?
    private var view: PrompterView?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var offset: CGFloat = 0
    /// Current scroll speed in points per second, eased toward the target (see ScrollMotion).
    private var velocity: CGFloat = 0
    private var countdownEnds: CFTimeInterval = 0
    private var currentScriptID: Script.ID?
    private var loadedBody: String?
    /// The script's words (same tokens as speech matching) and where they sit in the layout.
    private var wordRanges: [NSRange] = []
    private var wordLayout = WordLayout(ends: [], maxOffset: 0)
    private var appliedStyle = ""
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil
        )
        // Live-update the prompter while the current script is edited.
        store.$scripts
            .receive(on: RunLoop.main)
            .sink { [weak self] scripts in
                MainActor.assumeIsolated { self?.scriptsChanged(scripts) }
            }
            .store(in: &cancellables)
        follower.onMatch = { [weak self] index, lag in self?.spoke(wordAt: index, lag: lag) }
        follower.$status
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.view?.setFollowStatus(status) }
            }
            .store(in: &cancellables)
    }

    // MARK: Commands

    func start(_ script: Script) {
        start(script, testDrive: false)
    }

    /// Opens the real prompter with the practice script so settings can be tried while reading.
    func testDrive() {
        start(.practice, testDrive: true)
    }

    private func start(_ script: Script, testDrive: Bool) {
        if isTestDriving != testDrive {
            isTestDriving = testDrive
            if testDrive { recorder.stop() }
        }
        let switching = isVisible && currentScriptID != script.id
        currentScriptID = script.id
        loadedBody = script.body
        ensurePanel()
        reloadText()
        present()
        // A different script mid-session gets its own recording.
        if switching { updateRecording(newSession: true) }
        restart()
    }

    func togglePlayPause() {
        guard isVisible else {
            showOrStart(autoPlay: true)
            return
        }
        if isPlaying {
            isPlaying = false
            countdownEnds = 0
        } else {
            if offset >= maxOffset - 1 { offset = 0 }
            if offset == 0 { beginCountdown() }
            isPlaying = true
        }
    }

    func restart() {
        guard isVisible else { return }
        offset = 0
        view?.offset = 0
        pacer.reset()
        follower.reposition(toWord: -1)
        beginCountdown()
        isPlaying = true
    }

    func toggleVisibility() {
        if isVisible { hide() } else { showOrStart(autoPlay: false) }
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        isPlaying = false
        countdownEnds = 0
        stopTimer()
        isTestDriving = false
        updateVoiceUsage()
        updateRecording()
    }

    func jump(lines: Int) {
        guard isVisible, let view else { return }
        offset = clampOffset(offset + view.lineHeight * CGFloat(lines))
        view.offset = offset
        userMoved()
    }

    /// The prompter's own +/- buttons skip the toast; their label already shows the new speed.
    func changeSpeed(by delta: Double, announce: Bool = true) {
        Pref.speed += delta
        updateSpeedDisplay()
        if announce {
            view?.showToast(isTrackingWords ? "\(Int(Pref.speed)) wpm when not following" : "\(Int(Pref.speed)) wpm")
        }
    }

    // MARK: Panel

    @discardableResult
    private func ensurePanel() -> (PrompterPanel, PrompterView) {
        if let panel, let view { return (panel, view) }
        let panel = PrompterPanel()
        let view = PrompterView(frame: NSRect(origin: .zero, size: Pref.prompterSize))
        panel.contentView = view
        panel.delegate = self
        view.onTogglePause = { [weak self] in self?.togglePlayPause() }
        view.onClose = { [weak self] in self?.hide() }
        view.onChangeSpeed = { [weak self] direction in
            self?.changeSpeed(by: direction * Pref.speedStep, announce: false)
        }
        view.setFollowStatus(follower.status)
        view.onScroll = { [weak self] delta in
            guard let self else { return }
            self.offset = self.clampOffset(self.offset - delta)
            self.view?.offset = self.offset
            self.userMoved()
        }
        view.onMoveEnded = { [weak self] in self?.snapToTopIfClose() }
        view.onResizeEnded = { [weak self] in
            if let size = self?.panel?.frame.size { Pref.prompterSize = size }
        }
        view.onRelayout = { [weak self] in self?.layoutChanged() }
        self.panel = panel
        self.view = view
        updateSpeedDisplay()
        return (panel, view)
    }

    private func showOrStart(autoPlay: Bool) {
        if loadedBody != nil {
            present()
            if autoPlay { togglePlayPause() }
        } else if let script = store.scripts.first {
            start(script)
        }
    }

    private func present() {
        let (panel, _) = ensurePanel()
        if !isVisible { placeOnActiveScreen() }
        panel.sharingType = Pref.hideFromCapture ? .none : .readOnly
        panel.orderFrontRegardless()
        isVisible = true
        startTimer()
        updateVoiceUsage()
        updateRecording()
    }

    /// Centered at the top of whichever screen the pointer is on, directly under the camera.
    private func placeOnActiveScreen() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let size = Pref.prompterSize
        panel.setFrame(NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        ), display: true)
        updateAttachment()
    }

    private func snapToTopIfClose() {
        guard let panel, let screen = panel.screen else { return }
        let gap = screen.frame.maxY - panel.frame.maxY
        if gap != 0 && gap < 30 {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: screen.frame.maxY - panel.frame.height))
        }
        updateAttachment()
    }

    private func updateAttachment() {
        guard let panel, let view, let screen = panel.screen ?? NSScreen.main else { return }
        let attached = abs(panel.frame.maxY - screen.frame.maxY) < 2
        view.attachedToTop = attached
        view.notchInset = attached ? screen.safeAreaInsets.top : 0
    }

    func windowDidMove(_ notification: Notification) { updateAttachment() }
    func windowDidResize(_ notification: Notification) { updateAttachment() }
    func windowDidChangeScreen(_ notification: Notification) { updateAttachment() }

    // MARK: Text & settings

    private func reloadText() {
        guard let view else { return }
        let color = Pref.textColor
        wordRanges = ScriptAligner.tokens(in: loadedBody ?? "").map(\.range)
        let (text, lineHeight) = Self.styledText(loadedBody ?? "", fontSize: Pref.fontSize, color: color)
        view.setText(text, accent: color, lineHeight: lineHeight)   // reflows, then layoutChanged()
        appliedStyle = styleKey
        follower.load(loadedBody ?? "")
    }

    /// The text reflowed (font, width or script change). Rebuild the word map and keep the same
    /// word at the reading line, so changing size mid-read doesn't lose the reader's place.
    private func layoutChanged() {
        guard let view else { return }
        let reading = offset > 0.5 ? wordLayout.word(atOffset: offset) : nil
        wordLayout = WordLayout(
            ends: wordRanges.map { view.followOffset(forCharacterAt: NSMaxRange($0) - 1) ?? 0 },
            maxOffset: maxOffset
        )
        offset = clampOffset(reading.map { wordLayout.offset(atWord: $0) } ?? 0)
        view.offset = offset
    }

    /// The script as the prompter draws it, and its line height.
    static func styledText(_ body: String, fontSize: CGFloat, color: NSColor) -> (NSAttributedString, CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = (fontSize * 0.18).rounded()
        let text = NSMutableAttributedString(string: body, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        // Blank lines between paragraphs get a short line, not a full one, so gaps stay tight.
        let blankFont = NSFont.systemFont(ofSize: (fontSize * 0.4).rounded())
        let blankParagraph = NSMutableParagraphStyle()
        (text.string as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: text.length), options: .byParagraphs
        ) { line, _, enclosing, _ in
            if line?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                text.addAttributes([.font: blankFont, .paragraphStyle: blankParagraph], range: enclosing)
            }
        }
        return (text, NSLayoutManager().defaultLineHeight(for: font) + paragraph.lineSpacing)
    }

    private var styleKey: String { "\(Pref.fontSize)|\(Pref.textColor.hexString)" }

    @objc private func defaultsChanged() {
        if view != nil && styleKey != appliedStyle { reloadText() }
        updateSpeedDisplay()
        panel?.sharingType = Pref.hideFromCapture ? .none : .readOnly
        updateVoiceUsage()
        updateRecording()
    }

    /// Records while the prompter is showing and recording is on, from Start Prompting until it closes.
    private func updateRecording(newSession: Bool = false) {
        guard isVisible && Pref.recordSessions && !isTestDriving else {
            recorder.stop()
            return
        }
        if newSession || !recorder.isRecording {
            let title = store.scripts.first { $0.id == currentScriptID }?.title ?? "Recording"
            recorder.start(title: title)
        }
    }

    private func scriptsChanged(_ scripts: [Script]) {
        guard let id = currentScriptID, let script = scripts.first(where: { $0.id == id }),
              script.body != loadedBody else { return }
        loadedBody = script.body
        reloadText()
    }

    private func updateVoiceUsage() {
        let voiceMode = isVisible && Pref.scrollMode == .voice
        if voiceMode {
            voice.acquire("prompter")
        } else {
            voice.release("prompter")
        }
        follower.setActive(voiceMode && Pref.followWords, text: loadedBody ?? "")
    }

    // MARK: Following the speaker

    private var isFollowing: Bool { Pref.scrollMode == .voice && Pref.followWords }

    /// Following is on and recognition is working (or getting ready), so the speaker sets the pace.
    private var isTrackingWords: Bool {
        guard isFollowing else { return false }
        switch follower.status {
        case .listening, .following, .preparing: return true
        case .off, .denied, .dictationOff, .unavailable: return false
        }
    }

    /// Live measured pace while following words; the adjustable set speed otherwise.
    private func updateSpeedDisplay() {
        guard let view else { return }
        guard isTrackingWords, !wordRanges.isEmpty else {
            view.setSpeed(.adjustable(Int(Pref.speed)))
            return
        }
        view.setSpeed(.measured(Int((pacer.currentPace(wordsPerSecond) * 60).rounded())))
    }

    /// Recognition matched the speaker to a script word, spoken `lag` seconds ago.
    private func spoke(wordAt index: Int, lag: Double) {
        guard wordRanges.indices.contains(index) else { return }
        pacer.anchor(word: index, lag: lag, setPace: wordsPerSecond)
    }

    /// The user scrolled or jumped: look for the speaker from the new spot.
    private func userMoved() {
        pacer.reset()
        follower.reposition(toWord: Int(wordLayout.word(atOffset: offset).rounded(.down)))
    }

    // MARK: Scrolling

    private var maxOffset: CGFloat {
        guard let view else { return 0 }
        return max(0, view.textHeight - view.lineHeight)
    }

    /// The set speed. The word map turns it into scroll speed for the current layout.
    private var wordsPerSecond: Double { Pref.speed / 60 }

    private func clampOffset(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), maxOffset)
    }

    private func beginCountdown() {
        let seconds = Pref.countdown
        countdownEnds = seconds > 0 ? CACurrentMediaTime() + Double(seconds) : 0
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        guard let panel, let view else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now

        let hovering = panel.frame.contains(NSEvent.mouseLocation)
        let remaining = countdownEnds - now
        let counting = isPlaying && remaining > 0
        view.setCountdown(counting ? Int(remaining.rounded(.up)) : nil)

        let voiceMode = Pref.scrollMode == .voice
        // Pausing, hovering and the countdown stop the text at once; only the voice eases it.
        let running = isPlaying && !hovering && !counting
        let advancing = running && (!voiceMode || voice.isSpeaking)
        let following = voiceMode && isFollowing
        let reachedEnd = ScrollMotion.step(
            offset: &offset, velocity: &velocity, pacer: &pacer,
            dt: dt, running: running, speaking: !voiceMode || voice.isSpeaking, following: following,
            wordsPerSecond: wordsPerSecond, layout: wordLayout, lineHeight: view.lineHeight, maxOffset: maxOffset
        )
        if reachedEnd { isPlaying = false }

        view.offset = offset
        view.setPlaying(isPlaying)
        view.setRecording(since: recorder.startedAt)
        updateSpeedDisplay()
        view.setWaveform(
            level: CGFloat(voice.takePeak()), active: advancing,
            onScript: following && follower.isOnScript, visible: voiceMode
        )
    }
}
