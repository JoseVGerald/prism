import Foundation

/// The result of trying to make track B run at track A's tempo.
public struct TempoMatch: Equatable, Sendable {

    /// Playback rate to apply to B. 1.0 means no stretch is needed.
    public let rate: Double
    /// True when the two tempos are related by a factor of two — 85 and 170 are
    /// the same groove counted differently, and need no stretch at all.
    public let foldedOctave: Bool
    /// How far the rate is from 1, as a percentage.
    public var percentChange: Double { (rate - 1) * 100 }
    /// Whether the stretch is small enough to be inaudible.
    public let acceptable: Bool

    public init(rate: Double, foldedOctave: Bool, acceptable: Bool) {
        self.rate = rate
        self.foldedOctave = foldedOctave
        self.acceptable = acceptable
    }
}

public enum Tempo {

    /// Rate for B so that it beats along with A.
    ///
    /// Half- and double-time are folded first. A 170 BPM track over an 85 BPM
    /// one is not a 2× stretch problem, it is the same pulse — treating it
    /// naively would ask for a rate of 2.0 and be rejected as impossible when
    /// in fact nothing needs to change.
    ///
    /// - Parameter maxPercent: how much stretch is tolerable. Past about 6% the
    ///   change is audible even with pitch correction, and past 10% it sounds
    ///   wrong regardless.
    public static func match(from a: Double, to b: Double, maxPercent: Double = 6) -> TempoMatch {
        guard a > 0, b > 0 else {
            return TempoMatch(rate: 1, foldedOctave: false, acceptable: false)
        }

        var rate = a / b
        var folded = false
        // √2 is the crossover: past it, halving or doubling gets you closer to 1
        // than stretching does.
        while rate > 1.4142 { rate /= 2; folded = true }
        while rate < 0.7071 { rate *= 2; folded = true }

        let percent = abs((rate - 1) * 100)
        return TempoMatch(rate: rate, foldedOctave: folded, acceptable: percent <= maxPercent)
    }

    /// Seconds per beat.
    public static func beatDuration(bpm: Double) -> TimeInterval {
        guard bpm > 0 else { return 0 }
        return 60 / bpm
    }

    /// Length of a whole number of beats at a given tempo.
    public static func duration(beats: Int, bpm: Double) -> TimeInterval {
        beatDuration(bpm: bpm) * Double(max(beats, 0))
    }

    /// Picks a phrase length for the blend.
    ///
    /// Dance music is built in 4-bar groups, so transitions land best on 4, 8
    /// or 16 beats. Long blends need the two records to actually agree — if the
    /// tempo match is poor, or the two tracks differ a lot in loudness, a short
    /// transition hides the disagreement.
    /// - Parameters:
    ///   - atLeast: shortest the blend may be, in seconds. The phrase is
    ///     doubled until it covers this, so a slow floor lands on 8 or 16 beats
    ///     rather than on a ragged count part-way through a bar.
    ///   - bpm: tempo the phrase is counted at, needed to turn beats into time.
    public static func phraseBeats(match: TempoMatch,
                                   harmonic: HarmonicRelation?,
                                   energyDelta: Double,
                                   atLeast minimum: TimeInterval = 0,
                                   bpm: Double = 0) -> Int {

        var beats: Int = {
            guard match.acceptable else { return 4 }
            if let harmonic, !harmonic.allowsLongBlend { return 4 }

            let gentle = abs(match.percentChange) < 2
            let similarEnergy = abs(energyDelta) < 0.25

            if gentle && similarEnergy && (harmonic?.score ?? 0.5) >= 0.85 { return 16 }
            if similarEnergy || gentle { return 8 }
            return 4
        }()

        // Double, so the blend stays a whole number of bars. 32 is the ceiling:
        // beyond that the phrase is longer than most intros and outros and the
        // blend starts eating the body of the song.
        //
        // Only pairs that actually agree get their phrase grown. The 4-beat
        // answer above is a deliberate "these two do not belong together, keep
        // it brief" — doubling that to 16 to satisfy a time floor would take
        // the one case that wants to be short and make it the longest of all.
        // Such a pair still gets the floor, it just gets it as plain seconds
        // rather than as a phrase it has no business honouring.
        guard minimum > 0, bpm > 0, beats >= 8 else { return beats }
        while duration(beats: beats, bpm: bpm) < minimum, beats < 32 { beats *= 2 }
        return beats
    }
}
