import Foundation

/// One lyric line as the timing model sees it.
public struct TimedLine: Equatable, Sendable {
    /// Seconds into the track the line begins.
    public var start: Double
    public var text: String
    /// Exact start of every word, from enhanced LRC. Nil when the source only
    /// timed the line — which is nearly always.
    public var wordStarts: [Double]?

    public init(start: Double, text: String, wordStarts: [Double]? = nil) {
        self.start = start
        self.text = text
        self.wordStarts = wordStarts
    }
}

/// Where playback is within the lyrics at one instant.
public struct LyricMoment: Equatable, Sendable {
    /// The line being sung, or nil before the first line.
    public var lineIndex: Int?
    /// 0…1 through the current line's sung window.
    public var lineProgress: Double
    /// 0…1 for each word of the current line.
    public var wordProgress: [Double]
    /// Set during an instrumental stretch.
    public var gap: Gap?

    public struct Gap: Equatable, Sendable {
        public var elapsed: Double
        public var total: Double
        public var progress: Double { total > 0 ? min(max(elapsed / total, 0), 1) : 0 }
        public var remaining: Double { max(total - elapsed, 0) }
    }

    public static let before = LyricMoment(lineIndex: nil, lineProgress: 0,
                                           wordProgress: [], gap: nil)
}

/// Turns line-timed lyrics into word-level progress.
///
/// LRCLIB times **lines**, not words: standard LRC is one `[mm:ss.xx]` per
/// line. So "the words come up as they are sung" is necessarily an estimate,
/// and this is where it is made — in one pure place, with tests, rather than
/// scattered through five renderers. Where a source does carry enhanced-LRC
/// word stamps, those are used exactly instead.
public enum LyricTiming {

    /// Longest a line is allowed to be sung over. Past this the next line's
    /// start is usually after a held note or a break, not more singing.
    public static let maxLineSpan: Double = 8
    /// Breath left before the next line, so the fill finishes slightly early
    /// rather than dragging into the following line.
    public static let tail: Double = 0.35
    /// A silence longer than this between lines is shown as an instrumental.
    public static let gapThreshold: Double = 6

    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Roughly how long a line takes to sing, from its length alone.
    ///
    /// About thirteen characters a second plus a lead-in. It only decides
    /// anything when the *next* line is far away: without it, a two-word line
    /// before a long instrumental was assumed to be sung for the full
    /// `maxLineSpan`, which swallowed most of the break — a 12-second silence
    /// was never shown as a gap at all.
    public static func sungEstimate(_ text: String) -> Double {
        min(max(Double(text.count) * 0.075 + 0.8, 1.2), maxLineSpan)
    }

    /// When line `i` stops being sung: the earlier of the next line (less a
    /// breath) and how long this many words plausibly take.
    public static func end(of i: Int, in lines: [TimedLine]) -> Double {
        let start = lines[i].start
        var stop = start + sungEstimate(lines[i].text)
        if i + 1 < lines.count { stop = min(stop, lines[i + 1].start - tail) }
        return max(stop, start + 0.2)
    }

    /// Start and duration of every word in line `i`.
    ///
    /// Estimated by **character count**, not split evenly: "a" and
    /// "unbelievable" do not take the same time to sing, and weighting by
    /// length is the cheapest estimate that is visibly better than uniform.
    public static func wordWindows(in lines: [TimedLine], line i: Int)
        -> [(start: Double, duration: Double)] {
        let line = lines[i]
        let ws = words(line.text)
        guard !ws.isEmpty else { return [] }
        let start = line.start
        let stop = end(of: i, in: lines)

        if let exact = line.wordStarts, exact.count == ws.count {
            return exact.enumerated().map { k, s in
                let next = k + 1 < exact.count ? exact[k + 1] : stop
                return (s, max(next - s, 0.05))
            }
        }

        let weights = ws.map { Double(max($0.count, 1)) }
        let total = weights.reduce(0, +)
        let span = stop - start
        var cursor = start
        return weights.map { w in
            let d = span * w / total
            defer { cursor += d }
            return (cursor, d)
        }
    }

    public static func moment(in lines: [TimedLine], at time: Double) -> LyricMoment {
        guard !lines.isEmpty else { return .before }

        guard let i = lines.lastIndex(where: { $0.start <= time }) else {
            // Before the first line. A long intro is an instrumental too.
            let first = lines[0].start
            let gap = first >= gapThreshold
                ? LyricMoment.Gap(elapsed: time, total: first) : nil
            return LyricMoment(lineIndex: nil, lineProgress: 0, wordProgress: [], gap: gap)
        }

        let line = lines[i]
        let stop = end(of: i, in: lines)
        let span = stop - line.start
        let lineProgress = min(max((time - line.start) / span, 0), 1)
        let words = wordWindows(in: lines, line: i).map {
            min(max((time - $0.start) / $0.duration, 0), 1)
        }

        var gap: LyricMoment.Gap?
        if i + 1 < lines.count {
            let next = lines[i + 1].start
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty,
               next - line.start >= 2 {
                // LRC marks a break with an empty stamped line.
                gap = .init(elapsed: time - line.start, total: next - line.start)
            } else if time > stop, next - stop >= gapThreshold {
                gap = .init(elapsed: time - stop, total: next - stop)
            }
        }

        return LyricMoment(lineIndex: i, lineProgress: lineProgress,
                           wordProgress: words, gap: gap)
    }
}

/// LRC parsing, kept here so it can be tested.
public enum LRC {

    /// `[mm:ss.xx] text`, with repeated stamps for repeated phrases, and
    /// enhanced-LRC `<mm:ss.xx>` word stamps stripped from the text and kept
    /// as word times.
    public static func parse(_ raw: String) -> [TimedLine] {
        var out: [TimedLine] = []
        for line in raw.components(separatedBy: .newlines) {
            var rest = Substring(line)
            var stamps: [Double] = []
            while rest.first == "[" {
                guard let close = rest.firstIndex(of: "]") else { break }
                let body = rest[rest.index(after: rest.startIndex)..<close]
                // Metadata tags like [ar:Artist] fail to parse as a time and
                // are skipped, which is what they should be.
                if let s = seconds(body) { stamps.append(s) }
                rest = rest[rest.index(after: close)...]
            }
            guard let first = stamps.first else { continue }
            let (text, starts) = wordStamps(in: String(rest))
            for s in stamps {
                // Word stamps are absolute, so a repeated line shifts them by
                // the difference between its stamp and the first one.
                let shifted = starts.map { $0.map { $0 - first + s } }
                out.append(TimedLine(start: s, text: text, wordStarts: shifted))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func seconds<S: StringProtocol>(_ body: S) -> Double? {
        let parts = body.split(separator: ":")
        guard parts.count == 2,
              let m = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let s = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return m * 60 + s
    }

    private static let wordTag = try! NSRegularExpression(
        pattern: #"<\s*(\d+)\s*:\s*(\d+(?:\.\d+)?)\s*>"#)

    /// Clean text, plus a start per word — only when *every* word has one.
    /// Partial stamps are dropped rather than half-trusted: a mix of exact and
    /// guessed words would lurch where they meet.
    static func wordStamps(in text: String) -> (String, [Double]?) {
        let ns = text as NSString
        let matches = wordTag.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let clean = wordTag.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        let tidy = clean.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !matches.isEmpty else { return (tidy, nil) }

        var starts: [Double] = []
        var complete = true
        for (k, m) in matches.enumerated() {
            let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60
                  + (Double(ns.substring(with: m.range(at: 2))) ?? 0)
            let segEnd = k + 1 < matches.count ? matches[k + 1].range.location : ns.length
            let segStart = m.range.location + m.range.length
            let segment = ns.substring(with: NSRange(location: segStart,
                                                     length: max(segEnd - segStart, 0)))
            let n = LyricTiming.words(segment).count
            if n == 0 { continue }
            if n > 1 { complete = false }
            starts.append(t)
        }
        // Words before the first tag have no time of their own.
        let leading = ns.substring(to: matches[0].range.location)
        if !LyricTiming.words(leading).isEmpty { complete = false }

        let wordCount = LyricTiming.words(tidy).count
        return (tidy, complete && starts.count == wordCount ? starts : nil)
    }
}
