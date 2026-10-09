import AppKit

/// Borderless floating panel that sits over the menu bar / notch, on every Space and above full-screen apps.
final class PrompterPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Allow the panel to sit flush with the top of the screen, over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class GripView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for k: CGFloat in [4, 8, 12] {
            path.move(to: NSPoint(x: bounds.maxX - k, y: bounds.minY))
            path.line(to: NSPoint(x: bounds.maxX, y: bounds.minY + k))
        }
        path.stroke()
    }
}

/// A small voice waveform: thin bars whose heights are recent voice levels. The newest level is
/// in the middle and older ones ripple out to both sides and fade, so it stays centered under the camera.
/// Bars recorded while speech recognition was matching the script are green, like the follow dot.
private final class WaveformView: NSView {
    private let barsPerSide = 15
    private let pitch: CGFloat = 4
    private let sampleInterval: CFTimeInterval = 0.05
    private let bars = CAShapeLayer()
    private let onScriptBars = CAShapeLayer()
    private let edgeFade = CAGradientLayer()
    private var samples: [(level: CGFloat, onScript: Bool)]
    private var pending: CGFloat = 0
    private var pendingOnScript = false
    private var lastSample: CFTimeInterval = 0

    var preferredWidth: CGFloat { CGFloat(barsPerSide * 2 + 1) * pitch }

    override init(frame: NSRect) {
        samples = Array(repeating: (0, false), count: barsPerSide + 1)
        super.init(frame: frame)
        wantsLayer = true
        for layer in [bars, onScriptBars] {
            layer.lineWidth = 2
            layer.lineCap = .round
            layer.fillColor = nil
            self.layer?.addSublayer(layer)
        }
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
        edgeFade.colors = [NSColor.clear, .black, .black, .clear].map(\.cgColor)
        edgeFade.locations = [0, 0.3, 0.7, 1]
        layer?.mask = edgeFade
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called every frame; takes the loudest level of each 50 ms as one bar.
    func update(level: CGFloat, onScript: Bool, color: NSColor, onScriptColor: NSColor) {
        pending = max(pending, min(max(level, 0), 1))
        pendingOnScript = pendingOnScript || onScript
        let now = CACurrentMediaTime()
        if now - lastSample >= sampleInterval {
            lastSample = now
            samples.removeLast()
            samples.insert((pending, pendingOnScript), at: 0)
            pending = 0
            pendingOnScript = false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.frame = bounds
        onScriptBars.frame = bounds
        edgeFade.frame = bounds
        bars.strokeColor = color.cgColor
        onScriptBars.strokeColor = onScriptColor.cgColor
        let offPath = CGMutablePath(), onPath = CGMutablePath()
        let mid = bounds.midY, center = bounds.midX
        let tallest = bounds.height - bars.lineWidth
        for age in samples.indices {
            // Ends are rounded caps, so a silent bar is a dot.
            let half = max(0, tallest * samples[age].level - bars.lineWidth) / 2
            let path = samples[age].onScript ? onPath : offPath
            for side: CGFloat in age == 0 ? [0] : [-1, 1] {
                let x = center + side * CGFloat(age) * pitch
                path.move(to: CGPoint(x: x, y: mid - half))
                path.addLine(to: CGPoint(x: x, y: mid + half))
            }
        }
        bars.path = offPath
        onScriptBars.path = onPath
        CATransaction.commit()
    }
}

/// The prompter's content: black notch-shaped background, scrolling text with faded edges,
/// a voice waveform along the bottom, play/pause and speed controls and a close button in the top band.
/// It handles its own mouse input (click icons, drag to move, corner to resize, wheel to scroll).
final class PrompterView: NSView {
    var onTogglePause: (() -> Void)?
    var onClose: (() -> Void)?
    /// +1 for faster, -1 for slower.
    var onChangeSpeed: ((Double) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onMoveEnded: (() -> Void)?
    var onResizeEnded: (() -> Void)?
    /// The text reflowed (new text, font or width).
    var onRelayout: (() -> Void)?

    /// Height of the camera housing when the panel is flush with the top of a notched screen.
    var notchInset: CGFloat = 0 {
        didSet { if notchInset != oldValue { needsLayout = true } }
    }
    /// Flush with the top of the screen: square top corners, rounded bottom, like an extension of the notch.
    var attachedToTop = true {
        didSet { if attachedToTop != oldValue { needsLayout = true; needsDisplay = true } }
    }
    var offset: CGFloat = 0 {
        didSet { if offset != oldValue { positionText() } }
    }
    private(set) var textHeight: CGFloat = 0
    private(set) var lineHeight: CGFloat = 36

    private let cornerRadius: CGFloat = 18
    private let clip = FlippedView()
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let fade = CAGradientLayer()
    private let waveform = WaveformView()
    private let playIcon = NSImageView()
    private let closeIcon = NSImageView()
    private let slowerIcon = NSImageView()
    private let fasterIcon = NSImageView()
    private let speedLabel = NSTextField(labelWithString: "")
    private let followDot = NSView()
    private let recordDot = NSView()
    private let recordLabel = NSTextField(labelWithString: "")
    private let grip = GripView()
    private let countdownLabel = NSTextField(labelWithString: "")
    private let toastLabel = NSTextField(labelWithString: "")
    private var laidOutWidth: CGFloat = -1
    private var accent: NSColor = .white
    private var shownPlaying: Bool?
    private var toastGeneration = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.14, 0.82, 1]
        clip.layer?.mask = fade
        addSubview(clip)

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        clip.addSubview(textView)

        addSubview(waveform)

        for icon in [playIcon, closeIcon, slowerIcon, fasterIcon] {
            icon.symbolConfiguration = .init(pointSize: icon === playIcon || icon === closeIcon ? 11 : 10, weight: .bold)
            icon.contentTintColor = NSColor.white.withAlphaComponent(0.5)
            addSubview(icon)
        }
        closeIcon.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide prompter")
        slowerIcon.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Slower")
        fasterIcon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Faster")
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        speedLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        addSubview(speedLabel)

        followDot.wantsLayer = true
        followDot.layer?.cornerRadius = 3
        followDot.isHidden = true
        addSubview(followDot)

        recordDot.wantsLayer = true
        recordDot.layer?.cornerRadius = 3
        recordDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        recordLabel.textColor = NSColor.systemRed.withAlphaComponent(0.9)
        recordLabel.alignment = .right
        recordLabel.toolTip = "Recording your voice"
        for view in [recordDot, recordLabel] as [NSView] {
            view.isHidden = true
            addSubview(view)
        }
        setPlaying(false)

        countdownLabel.alignment = .center
        countdownLabel.textColor = .white
        countdownLabel.isHidden = true
        addSubview(countdownLabel)

        toastLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        toastLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        toastLabel.alphaValue = 0
        addSubview(toastLabel)

        addSubview(grip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Drawing & layout

    override func draw(_ dirtyRect: NSRect) {
        // When attached, extend the rounded rect above the top edge so only the bottom corners are rounded.
        let r = cornerRadius
        let rect = attachedToTop ? NSRect(x: 0, y: -r, width: bounds.width, height: bounds.height + r) : bounds
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let band = attachedToTop ? max(notchInset, 26) : 26
        let side: CGFloat = 16
        let iconSize: CGFloat = 16
        let iconY = ((band - iconSize) / 2).rounded()

        playIcon.frame = NSRect(x: side - 2, y: iconY, width: iconSize, height: iconSize)
        closeIcon.frame = NSRect(x: w - side - iconSize + 2, y: iconY, width: iconSize, height: iconSize)
        // Speed sits on the left next to play/pause, clear of a camera notch in the middle.
        // Kept compact so it ends left of a 14"/16" MacBook notch at the default width.
        let small: CGFloat = 12
        let smallY = iconY + (iconSize - small) / 2
        slowerIcon.frame = NSRect(x: playIcon.frame.maxX + 8, y: smallY, width: small, height: small)
        let widest = NSAttributedString(string: "300 wpm", attributes: [.font: speedLabel.font as Any]).size()
        speedLabel.frame = NSRect(
            x: slowerIcon.frame.maxX + 2, y: (iconY + (iconSize - widest.height) / 2).rounded(),
            width: ceil(widest.width) + 4, height: ceil(widest.height)
        )
        fasterIcon.frame = NSRect(x: speedLabel.frame.maxX + 2, y: smallY, width: small, height: small)
        if slowerIcon.isHidden {
            // Read-only pace: no buttons, so start where "-" would be and take the room it leaves.
            speedLabel.frame.origin.x = slowerIcon.frame.minX
            speedLabel.frame.size.width = fasterIcon.frame.maxX - slowerIcon.frame.minX
        }
        speedLabel.alignment = slowerIcon.isHidden ? .left : .center
        followDot.frame = NSRect(x: closeIcon.frame.minX - 14, y: (iconY + iconSize / 2 - 3).rounded(), width: 6, height: 6)
        // Recording sits left of the follow dot: a red dot and the elapsed time.
        let timeSize = recordLabel.intrinsicContentSize
        recordLabel.frame = NSRect(
            x: followDot.frame.minX - 10 - ceil(timeSize.width), y: (iconY + (iconSize - timeSize.height) / 2).rounded(),
            width: ceil(timeSize.width), height: ceil(timeSize.height)
        )
        recordDot.frame = NSRect(x: recordLabel.frame.minX - 10, y: followDot.frame.minY, width: 6, height: 6)
        clip.frame = NSRect(x: side + 4, y: band, width: max(0, w - 2 * (side + 4)), height: max(0, h - band - 14))
        grip.frame = NSRect(x: w - 16, y: h - 16, width: 12, height: 12)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = clip.bounds
        CATransaction.commit()

        countdownLabel.sizeToFit()
        countdownLabel.setFrameOrigin(NSPoint(
            x: (clip.frame.midX - countdownLabel.frame.width / 2).rounded(),
            y: (clip.frame.midY - countdownLabel.frame.height / 2).rounded()
        ))

        if clip.bounds.width != laidOutWidth { relayoutText() } else { positionText() }
        needsDisplay = true
    }

    private func relayoutText() {
        let width = clip.bounds.width
        laidOutWidth = width
        guard width > 0, let container = textView.textContainer, let manager = textView.layoutManager else { return }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        textHeight = ceil(manager.usedRect(for: container).height)
        textView.setFrameSize(NSSize(width: width, height: textHeight + lineHeight))
        positionText()
        onRelayout?()
    }

    /// First line starts just below the top fade; offset scrolls the text upward.
    private func positionText() {
        let leadIn = (clip.bounds.height * 0.16).rounded()
        let y = ((leadIn - offset) * 2).rounded() / 2
        textView.setFrameOrigin(NSPoint(x: 0, y: y))
    }

    // MARK: Following the speaker

    /// Scroll offset for reading the given character: its line moves from the second row up to
    /// the first as the reader goes from its start to its end, so motion is continuous.
    func followOffset(forCharacterAt index: Int) -> CGFloat? {
        guard let manager = textView.layoutManager, let container = textView.textContainer,
              let length = textView.textStorage?.length, length > 0 else { return nil }
        let glyph = manager.glyphIndexForCharacter(at: min(max(index, 0), length - 1))
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphEnd = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
        let fraction = used.width > 0 ? min(max(glyphEnd / used.maxX, 0), 1) : 1
        return line.minY - line.height * (1 - fraction)
    }

    // MARK: State from the controller

    func setText(_ text: NSAttributedString, accent: NSColor, lineHeight: CGFloat) {
        textView.textStorage?.setAttributedString(text)
        self.accent = accent
        self.lineHeight = lineHeight
        countdownLabel.font = .systemFont(ofSize: max(36, lineHeight * 1.6), weight: .bold)
        countdownLabel.textColor = accent
        laidOutWidth = -1
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setPlaying(_ playing: Bool) {
        guard shownPlaying != playing else { return }
        shownPlaying = playing
        playIcon.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? "Pause" : "Play"
        )
    }

    /// Green while speech recognition has the speaker's place, dim while it is listening for it.
    func setFollowStatus(_ status: SpeechFollower.Status) {
        switch status {
        case .following:
            followDot.isHidden = false
            followDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            followDot.toolTip = "Following your words"
        case .listening, .preparing:
            followDot.isHidden = false
            followDot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
            followDot.toolTip = status == .preparing ? "Downloading the speech model" : "Listening for your place in the script"
        case .off, .denied, .dictationOff, .unavailable:
            followDot.isHidden = true
        }
    }

    /// Shows the recording indicator and elapsed time while recording; hides it for nil.
    func setRecording(since start: Date?) {
        guard let start else {
            recordDot.isHidden = true
            recordLabel.isHidden = true
            return
        }
        let seconds = Int(Date().timeIntervalSince(start))
        let text = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        if recordLabel.stringValue != text {
            if recordLabel.stringValue.count != text.count { needsLayout = true }
            recordLabel.stringValue = text
        }
        recordDot.isHidden = false
        recordLabel.isHidden = false
    }

    enum SpeedDisplay: Equatable {
        /// The set speed is in charge: show it with -/+ buttons.
        case adjustable(Int)
        /// Following the speaker: show their measured pace, read-only.
        case measured(Int)
    }

    func setSpeed(_ display: SpeedDisplay) {
        let text: String, adjustable: Bool
        switch display {
        case .adjustable(let wpm): (text, adjustable) = ("\(wpm) wpm", true)
        case .measured(let wpm): (text, adjustable) = ("~\(wpm) wpm", false)
        }
        guard speedLabel.stringValue != text || slowerIcon.isHidden == adjustable else { return }
        speedLabel.stringValue = text
        if slowerIcon.isHidden == adjustable { needsLayout = true }
        slowerIcon.isHidden = !adjustable
        fasterIcon.isHidden = !adjustable
        speedLabel.toolTip = adjustable ? nil : "Your speaking pace, measured from your words"
    }

    func setCountdown(_ value: Int?) {
        let text = value.map(String.init) ?? ""
        guard countdownLabel.stringValue != text || countdownLabel.isHidden != (value == nil) else { return }
        countdownLabel.stringValue = text
        countdownLabel.isHidden = value == nil
        textView.alphaValue = value == nil ? 1 : 0.2
        needsLayout = true
    }

    /// `level` is 0...1 above the room's noise; `active` while the voice is moving the text;
    /// `onScript` while speech recognition is matching the speaker's words to the script.
    func setWaveform(level: CGFloat, active: Bool, onScript: Bool, visible: Bool) {
        waveform.isHidden = !visible
        guard visible else { return }
        let width = waveform.preferredWidth
        waveform.frame = NSRect(x: (bounds.midX - width / 2).rounded(), y: bounds.height - 17, width: width, height: 15)
        waveform.update(
            level: level, onScript: onScript,
            color: accent.withAlphaComponent(active ? 0.9 : 0.35),
            onScriptColor: NSColor.systemGreen.withAlphaComponent(active ? 1 : 0.5)
        )
    }

    func showToast(_ message: String) {
        toastLabel.stringValue = message
        toastLabel.sizeToFit()
        toastLabel.setFrameOrigin(NSPoint(
            x: (bounds.midX - toastLabel.frame.width / 2).rounded(),
            y: bounds.height - 30
        ))
        toastLabel.alphaValue = 1
        toastGeneration += 1
        let generation = toastGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.toastGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.toastLabel.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Take every event ourselves so the text view never selects or steals clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if playIcon.frame.insetBy(dx: -8, dy: -8).contains(p) {
            onTogglePause?()
        } else if closeIcon.frame.insetBy(dx: -8, dy: -8).contains(p) {
            onClose?()
        } else if !slowerIcon.isHidden && slowerIcon.frame.insetBy(dx: -4, dy: -8).contains(p) {
            repeatWhileHeld(-1)
        } else if !fasterIcon.isHidden && fasterIcon.frame.insetBy(dx: -4, dy: -8).contains(p) {
            repeatWhileHeld(1)
        } else if NSRect(x: bounds.maxX - 24, y: bounds.maxY - 24, width: 24, height: 24).contains(p) {
            trackResize()
        } else {
            window?.performDrag(with: event)
            onMoveEnded?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * lineHeight
        onScroll?(delta)
    }

    /// One step per click; holding the button keeps stepping, about 16 per second after a short delay.
    private func repeatWhileHeld(_ direction: Double) {
        onChangeSpeed?(direction)
        guard let window else { return }
        var delay = 0.4
        while window.nextEvent(
            matching: .leftMouseUp, until: Date(timeIntervalSinceNow: delay), inMode: .eventTracking, dequeue: true
        ) == nil {
            onChangeSpeed?(direction)
            delay = 0.06
        }
    }

    private func trackResize() {
        guard let window else { return }
        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y
            var frame = startFrame
            if attachedToTop {
                // Stay centered under the camera while resizing.
                frame.size.width = max(260, startFrame.width + dx * 2)
                frame.origin.x = startFrame.midX - frame.width / 2
            } else {
                frame.size.width = max(260, startFrame.width + dx)
            }
            frame.size.height = max(110, startFrame.height - dy)
            frame.origin.y = startFrame.maxY - frame.height
            window.setFrame(frame, display: true)
            if event.type == .leftMouseUp { break }
        }
        onResizeEnded?()
    }
}
