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
    /// Current scroll speed in points per second, eased toward the target.
    private var velocity: CGFloat = 0
    /// Speeding up approaches the set pace exponentially: about 95% of it within 0.45 s.
    private let takeOffTime: CGFloat = 0.15
    /// Slowing down brakes at a steady rate, like a car: from full pace to a stop in 0.6 s.
    private let brakeTime: CGFloat = 0.6
    private var countdownEnds: CFTimeInterval = 0
    private var currentScriptID: Script.ID?
    private var loadedBody: String?
    private var wordCount = 0
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
        let fontSize = Pref.fontSize
        let color = Pref.textColor
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = (fontSize * 0.18).rounded()
        wordCount = Script(title: "", body: loadedBody ?? "").wordCount
        let text = NSMutableAttributedString(string: loadedBody ?? "", attributes: [
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
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font) + paragraph.lineSpacing
        view.setText(text, accent: color, lineHeight: lineHeight)
        appliedStyle = styleKey
        follower.load(loadedBody ?? "")
        offset = clampOffset(offset)
        view.offset = offset
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
        guard isVisible && Pref.recordSessions else {
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
        guard isTrackingWords, wordCount > 0, view.textHeight > 0 else {
            view.setSpeed(.adjustable(Int(Pref.speed)))
            return
        }
        let pointsPerWord = view.textHeight / CGFloat(wordCount)
        let wpm = pacer.currentPace(pointsPerSecond) / pointsPerWord * 60
        view.setSpeed(.measured(Int(wpm.rounded())))
    }

    /// Recognition matched the speaker to a script word, spoken `lag` seconds ago.
    private func spoke(wordAt index: Int, lag: Double) {
        guard let view, follower.aligner.words.indices.contains(index) else { return }
        let range = follower.aligner.words[index].range
        guard let target = view.followOffset(forCharacterAt: NSMaxRange(range) - 1) else { return }
        pacer.anchor(clampOffset(target), lag: lag, setPace: pointsPerSecond)
    }

    /// The user scrolled or jumped: look for the speaker from the new spot.
    private func userMoved() {
        guard let view else { return }
        pacer.reset()
        let character = view.characterIndex(atOffset: offset)
        follower.reposition(toWord: follower.aligner.wordIndex(atCharacter: character) - 1)
    }

    // MARK: Scrolling

    private var maxOffset: CGFloat {
        guard let view else { return 0 }
        return max(0, view.textHeight - view.lineHeight)
    }

    /// Turns words per minute into scroll speed using how tall this script's text actually is,
    /// so the setting holds at any font size or prompter width.
    private var pointsPerSecond: CGFloat {
        guard let view, wordCount > 0 else { return 0 }
        return CGFloat(Pref.speed / 60) * view.textHeight / CGFloat(wordCount)
    }

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
        let pace = following ? pacer.currentPace(pointsPerSecond) : pointsPerSecond
        var target = advancing ? pace : 0
        var immediate = false
        if following {
            switch pacer.command(
                offset: offset, speaking: advancing, dt: dt, setPace: pointsPerSecond, lineHeight: view.lineHeight
            ) {
            case .cruise(let speed): target = speed
            case .jump(let speed): target = speed; immediate = true
            }
        }
        let step = CGFloat(dt)
        if !running {
            velocity = 0
        } else if immediate {
            velocity = target
        } else if target > velocity {
            velocity += (target - velocity) * (1 - exp(-step / takeOffTime))
        } else {
            velocity = max(target, velocity - max(pace, 1) / brakeTime * step)
        }
        if velocity != 0 {
            // Only a jump back to text being re-read moves backward.
            offset = clampOffset(offset + velocity * step)
            if offset >= maxOffset && velocity > 0 {
                isPlaying = false
                velocity = 0
            }
        }

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
