import CoreGraphics

/// Turns word positions from speech recognition into a smooth scroll speed.
///
/// Each recognition sets a predicted position, which then moves on at the speaker's measured pace
/// for a short while; the scroll speed is that pace plus a gentle pull toward the prediction.
/// Pace is measured in points per second of speaking, so pauses don't drag it down, and starts at
/// the user's set pace. If recognitions stop while the speaker keeps talking (an ad-lib, or a jump
/// not yet found) the prediction stops too and the text holds; after a long stretch without any,
/// recognition is probably struggling and it falls back to plain pace.
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

    private(set) var measuredPace: CGFloat?
    private var predicted: CGFloat?
    private var speakingClock: Double = 0
    private var lastAnchorClock: Double = -.infinity
    private var anchors: [(clock: Double, offset: CGFloat)] = []

    var isLocked: Bool { predicted != nil }

    /// Forget everything, e.g. after a restart or a manual scroll.
    mutating func reset() {
        measuredPace = nil
        predicted = nil
        anchors.removeAll()
        lastAnchorClock = -.infinity
    }

    func currentPace(_ setPace: CGFloat) -> CGFloat { measuredPace ?? setPace }

    /// Recognition placed the speaker at this scroll offset `lag` seconds ago.
    mutating func anchor(_ target: CGFloat, lag: Double, setPace: CGFloat) {
        // A big jump starts pace measurement over; it says nothing about speed.
        if let last = anchors.last, abs(target - last.offset) > max(setPace, 1) * 6 { anchors.removeAll() }
        anchors.append((speakingClock - lag, target))
        anchors.removeAll { speakingClock - $0.clock > paceWindow }
        if let first = anchors.first, let last = anchors.last, last.clock - first.clock >= 3 {
            let pace = (last.offset - first.offset) / CGFloat(last.clock - first.clock)
            let clamped = min(max(pace, setPace * 0.5), setPace * 2)
            measuredPace = measuredPace.map { $0 * 0.7 + clamped * 0.3 } ?? clamped
        }
        predicted = target + currentPace(setPace) * CGFloat(lag)
        lastAnchorClock = speakingClock
    }

    /// Speed to scroll at this tick. `speaking` is false while silent, hovered or paused.
    mutating func command(offset: CGFloat, speaking: Bool, dt: Double, setPace: CGFloat, lineHeight: CGFloat) -> Command {
        let pace = currentPace(setPace)
        guard speaking else { return .cruise(0) }
        speakingClock += dt
        let sinceAnchor = speakingClock - lastAnchorClock
        if sinceAnchor > giveUpAfter { predicted = nil }
        guard var target = predicted else { return .cruise(pace) }

        // Carry the prediction forward only shortly past the last recognized word.
        let leading = sinceAnchor <= maxLead
        if leading { target += pace * CGFloat(dt) }
        predicted = target

        let gap = target - offset
        // Skipping ahead, or text the speaker is reading has scrolled out of sight above:
        // get there in about half a second.
        if gap > lineHeight * 3 || gap < -lineHeight * 1.2 {
            return .jump(gap / 0.5)
        }
        let feedForward = leading ? pace : 0
        return .cruise(min(max(feedForward + correctionGain * gap, 0), pace * 2.5))
    }
}
