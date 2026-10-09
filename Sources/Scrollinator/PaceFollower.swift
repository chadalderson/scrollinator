import CoreGraphics

/// Turns word positions from speech recognition into a smooth scroll speed.
///
/// It works in words, the way people read: each recognition sets a predicted word position,
/// which then moves on at the speaker's measured pace (words per second of speaking, so pauses
/// don't drag it down) for a short while. Every frame the prediction is placed in the current
/// layout, so short lines, paragraph gaps and font or width changes don't distort it. The scroll
/// speed follows the prediction plus a gentle pull toward it. If recognitions stop while the
/// speaker keeps talking (an ad-lib, or a jump not yet found) the prediction stops and the text
/// holds; after a long stretch without any, it falls back to plain pace.
struct PaceFollower {
    enum Command {
        /// Ease toward this speed (take-off and braking apply).
        case cruise(CGFloat)
        /// The speaker is far from the text (a jump, or reading text above); move at this speed directly.
        case jump(CGFloat)
    }

    /// Fraction of the gap to the predicted position closed per second.
    var correctionGain: CGFloat = 1.2
    /// Seconds of speaking the prediction may run past the last recognized word.
    var maxLead: Double = 1.5
    /// Seconds of speaking without a recognition before giving up and scrolling at plain pace.
    var giveUpAfter: Double = 10
    /// Pace is measured over this much recent speaking time.
    var paceWindow: Double = 12

    /// Words per second of speaking.
    private(set) var measuredPace: Double?
    /// Fractional word position the speaker is predicted to be at.
    private var predicted: Double?
    private var speakingClock: Double = 0
    private var lastAnchorClock: Double = -.infinity
    private var anchors: [(clock: Double, word: Double)] = []

    var isLocked: Bool { predicted != nil }

    /// Forget everything, e.g. after a restart or a manual scroll.
    mutating func reset() {
        measuredPace = nil
        predicted = nil
        anchors.removeAll()
        lastAnchorClock = -.infinity
    }

    /// Words per second: measured, or the set pace until there's enough to measure.
    func currentPace(_ setPace: Double) -> Double { measuredPace ?? setPace }

    /// Recognition heard script word `word`, spoken `lag` seconds ago.
    mutating func anchor(word: Int, lag: Double, setPace: Double) {
        let position = Double(word)
        // A skip or re-read starts pace measurement over: moving further than anyone could read
        // in the time since the last recognized word (or backward) says nothing about speed.
        if let last = anchors.last {
            let elapsed = max(speakingClock - lag - last.clock, 0)
            let plausible = 4 + currentPace(setPace) * elapsed * 2
            if position - last.word > plausible || position < last.word - 2 { anchors.removeAll() }
        }
        anchors.append((speakingClock - lag, position))
        anchors.removeAll { speakingClock - $0.clock > paceWindow }
        if let first = anchors.first, let last = anchors.last, last.clock - first.clock >= 3 {
            let pace = (last.word - first.word) / (last.clock - first.clock)
            let clamped = min(max(pace, setPace * 0.5), setPace * 2)
            measuredPace = measuredPace.map { $0 * 0.7 + clamped * 0.3 } ?? clamped
        }
        predicted = position + currentPace(setPace) * lag
        lastAnchorClock = speakingClock
    }

    /// Speed to scroll at this tick, in points per second. `speaking` is false while silent,
    /// hovered or paused.
    mutating func command(
        offset: CGFloat, speaking: Bool, dt: Double, setPace: Double, layout: WordLayout, lineHeight: CGFloat
    ) -> Command {
        let pace = currentPace(setPace)
        guard speaking else { return .cruise(0) }
        speakingClock += dt
        let sinceAnchor = speakingClock - lastAnchorClock
        if sinceAnchor > giveUpAfter { predicted = nil }
        guard var position = predicted else {
            return .cruise(CGFloat(pace) * layout.pointsPerWord(atWord: layout.word(atOffset: offset)))
        }

        // Carry the prediction forward only shortly past the last recognized word.
        let leading = sinceAnchor <= maxLead
        if leading { position += pace * dt }
        predicted = position
        let target = layout.offset(atWord: position)

        let gap = target - offset
        // Skipping ahead, or text the speaker is reading has scrolled out of sight above:
        // get there in about half a second.
        if gap > lineHeight * 3 || gap < -lineHeight * 1.2 {
            return .jump(gap / 0.5)
        }
        // Base speed from the average word spacing around the prediction, not the frame-to-frame
        // step: a paragraph gap is a sudden step that would otherwise spike the speed and overshoot.
        let local = CGFloat(pace) * layout.pointsPerWord(atWord: position)
        let feedForward = leading ? local : 0
        return .cruise(min(max(feedForward + correctionGain * gap, 0), local * 2.5))
    }
}
