import Foundation

/// Finds where in the script the speaker is from the words recognized so far.
/// It fuzzy-matches the last few recognized words against the script near the current spot
/// (local alignment), so misheard words, skipped words and ad-libs only weaken a match.
/// If nothing matches nearby, a stricter search over the whole script catches jumps.
struct ScriptAligner {
    struct Word {
        let key: String
        let range: NSRange
    }

    let words: [Word]
    /// Index of the last word the speaker said; -1 before the first word.
    private(set) var position = -1

    private let tailLength = 10
    private let nearbyBehind = 30
    private let nearbyAhead = 60
    private let nearbyMinScore: Double = 2.2
    private let anywhereMinScore: Double = 4.5
    /// Caps on how much matching evidence can carry forward, so a strong run of old words can't
    /// pay for skipping ahead to a lone short word (an "I" in an ad-lib matching an "I" further on).
    /// A new position has to be earned by the words just spoken.
    private let nearbyCap: Double = 3.0
    private let anywhereCap: Double = 5.0
    private let gapPenalty: Double = 0.5

    init(text: String) {
        words = Self.tokens(in: text).map { Word(key: $0.key, range: $0.range) }
    }

    mutating func reposition(to index: Int) {
        position = min(max(index, -1), words.count - 1)
    }

    /// Index of the word containing or following a character offset.
    func wordIndex(atCharacter location: Int) -> Int {
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(words[mid].range) <= location { lo = mid + 1 } else { hi = mid }
        }
        return min(lo, words.count - 1)
    }

    /// Feeds the full recognized transcript of the current recognition session.
    /// Returns the new position when the end of it matches the script confidently.
    mutating func update(recognized transcript: String) -> Int? {
        guard !words.isEmpty else { return nil }
        let heard = Self.tokens(in: transcript).suffix(tailLength).map(\.key)
        guard heard.count >= 3 else { return nil }

        let lo = max(0, position - nearbyBehind)
        let hi = min(words.count, max(position, 0) + nearbyAhead)
        if let found = bestMatch(heard, in: lo..<hi, minScore: nearbyMinScore, cap: nearbyCap)
            ?? bestMatch(heard, in: 0..<words.count, minScore: anywhereMinScore, cap: anywhereCap) {
            position = found
            return found
        }
        return nil
    }

    /// Smith-Waterman local alignment of the heard words against a slice of the script.
    /// The match must end on one of the last two heard words actually matching a script word,
    /// so it describes where the speaker is now: older words matching says nothing about an ad-lib.
    private func bestMatch(_ heard: [String], in range: Range<Int>, minScore: Double, cap: Double) -> Int? {
        let n = heard.count, m = range.count
        guard m > 0 else { return nil }
        var prev = [Double](repeating: 0, count: m + 1)
        var cur = prev
        var best: (score: Double, end: Int)?
        for i in 1...n {
            cur[0] = 0
            for j in 1...m {
                let similarity = Self.similarity(heard[i - 1], words[range.lowerBound + j - 1].key)
                let diag = prev[j - 1] + similarity
                let raw = max(0, diag, prev[j] - gapPenalty, cur[j - 1] - gapPenalty)
                cur[j] = min(raw, cap)
                guard i >= n - 1, similarity > 0, raw == diag, cur[j] >= minScore else { continue }
                // A last word that didn't match (often half-recognized) is assumed to follow on.
                let end = min(range.lowerBound + j - 1 + (n - i), words.count - 1)
                if let b = best {
                    let closer = abs(end - position) < abs(b.end - position)
                    if cur[j] > b.score + 0.01 || (abs(cur[j] - b.score) <= 0.01 && closer) { best = (cur[j], end) }
                } else {
                    best = (cur[j], end)
                }
            }
            swap(&prev, &cur)
        }
        return best?.end
    }

    /// Short words like "the" and "a" are common everywhere, so they count for less.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return a.count <= 3 ? 0.6 : 1.0 }
        let shorter = min(a.count, b.count), longer = max(a.count, b.count)
        guard shorter >= 4 else { return -0.6 }
        if a.hasPrefix(b) || b.hasPrefix(a) { return 0.6 }
        if editDistance(a, b) <= (longer >= 8 ? 2 : 1) { return 0.7 }
        return -0.6
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diag = row[0]
            row[0] = i
            for j in 1...b.count {
                let up = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, diag + (a[i - 1] == b[j - 1] ? 0 : 1))
                diag = up
            }
        }
        return row[b.count]
    }

    // MARK: Tokens

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "hundred": "100", "thousand": "1000",
    ]

    /// Lowercased words without accents or punctuation; number words become digits,
    /// since recognition writes "10" where a script may say "ten".
    static func tokens(in text: String) -> [(key: String, range: NSRange)] {
        var out: [(key: String, range: NSRange)] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let key = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
            guard !key.isEmpty else { return }
            out.append((numberWords[key] ?? key, range))
        }
        return out
    }
}
