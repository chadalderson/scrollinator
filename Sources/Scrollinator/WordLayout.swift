import CoreGraphics

/// Where each script word sits in the prompter's scroll space, so following can work in words
/// (how people read) and convert to scroll offsets for the current layout. `ends[i]` is the
/// offset at which word i has just been read (PrompterView.followOffset), clamped to the
/// scrollable range. Rebuilt whenever the text reflows, after a font or width change.
struct WordLayout {
    private(set) var ends: [CGFloat]

    init(ends raw: [CGFloat], maxOffset: CGFloat) {
        var running: CGFloat = 0
        ends = raw.map { value in
            running = max(running, min(max(value, 0), maxOffset))
            return running
        }
    }

    var isEmpty: Bool { ends.isEmpty }

    /// Offset for a fractional word position: -1 is before the first word, 2.5 is halfway
    /// between the ends of words 2 and 3.
    func offset(atWord position: Double) -> CGFloat {
        guard !ends.isEmpty, position > -1 else { return 0 }
        let last = ends.count - 1
        if position >= Double(last) { return ends[last] }
        let i = Int(position.rounded(.down))
        let from = i < 0 ? 0 : ends[i]
        return from + (ends[i + 1] - from) * CGFloat(position - Double(i))
    }

    /// The word position being read at an offset (the inverse of `offset(atWord:)`).
    func word(atOffset offset: CGFloat) -> Double {
        guard !ends.isEmpty else { return -1 }
        // The last word whose end is at or before the offset, then partway toward the next.
        var lo = 0, hi = ends.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] <= offset { lo = mid + 1 } else { hi = mid }
        }
        let i = lo - 1
        guard i >= 0 else { return -1 }
        guard i + 1 < ends.count, ends[i + 1] > ends[i] else { return Double(i) }
        return Double(i) + Double((offset - ends[i]) / (ends[i + 1] - ends[i]))
    }

    /// Scroll distance per word around a position, averaged over a few words so a single
    /// paragraph gap doesn't spike it.
    func pointsPerWord(atWord position: Double) -> CGFloat {
        guard ends.count > 1 else { return 0 }
        return (offset(atWord: position + 3) - offset(atWord: position - 3)) / 6
    }
}
