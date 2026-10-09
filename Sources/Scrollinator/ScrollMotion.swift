import CoreGraphics

/// One frame of the prompter's motion: eases the text toward its target speed (quick take-off,
/// steady braking) and, while following the speaker, takes that target from PaceFollower.
/// Shared by PrompterController and the tracking tests so both run exactly the same math.
enum ScrollMotion {
    /// Speeding up approaches the target exponentially: about 95% of it within 0.45 s.
    static let takeOffTime: CGFloat = 0.15
    /// Slowing down brakes at a steady rate, like a car: from full pace, or from a faster catch-up
    /// such as a quick hop across a paragraph break, to a stop in 0.6 s.
    static let brakeTime: CGFloat = 0.6

    /// Advances `offset` by one frame. `running` is false while paused, hovered or counting down;
    /// `speaking` is whether the voice is moving the text (always true at constant speed).
    /// `wordsPerSecond` is the set pace; `layout` places words in the current text layout.
    /// Returns true when the text reached the end.
    static func step(
        offset: inout CGFloat, velocity: inout CGFloat, pacer: inout PaceFollower,
        dt: Double, running: Bool, speaking: Bool, following: Bool,
        wordsPerSecond: Double, layout: WordLayout, lineHeight: CGFloat, maxOffset: CGFloat
    ) -> Bool {
        let advancing = running && speaking
        // The set or measured pace, as scroll speed for the words around the reading line.
        let wordsPace = following ? pacer.currentPace(wordsPerSecond) : wordsPerSecond
        let pace = CGFloat(wordsPace) * layout.pointsPerWord(atWord: layout.word(atOffset: offset))
        var target = advancing ? pace : 0
        var immediate = false
        if following {
            switch pacer.command(offset: offset, speaking: advancing, dt: dt, setPace: wordsPerSecond,
                                 layout: layout, lineHeight: lineHeight) {
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
            velocity = max(target, velocity - max(pace, velocity, 1) / brakeTime * step)
        }
        guard velocity != 0 else { return false }
        // Only a jump back to text being re-read moves backward.
        offset = min(max(offset + velocity * step, 0), maxOffset)
        if offset >= maxOffset && velocity > 0 {
            velocity = 0
            return true
        }
        return false
    }
}
