import Foundation

/// Finds the beat in a stream of onset strength: how long a beat lasts, and
/// when the last one landed.
///
/// Tempo is the lag at which the recent onset envelope best matches itself
/// (autocorrelation), weighted towards the tempos music is usually written at
/// and towards lags whose double also matches, so a busy hi-hat does not read
/// as double time. Phase is then the offset at which a comb of that spacing
/// collects the most onset energy.
///
/// Pure and clock-free: time is sample index over `rate`, so it tests without
/// audio and the caller maps it to wall-clock time.
public struct TempoTracker: Sendable {

    public struct Beat: Equatable, Sendable {
        /// Seconds per beat.
        public var period: Double
        /// When the most recent beat landed, in seconds on the tracker's clock.
        public var lastBeat: Double
        /// Normalised autocorrelation at the chosen lag, roughly 0…1. Low means
        /// the music has no steady pulse to speak of.
        public var confidence: Double

        public init(period: Double, lastBeat: Double, confidence: Double) {
            self.period = period
            self.lastBeat = lastBeat
            self.confidence = confidence
        }
    }

    /// Onset-strength samples per second.
    public let rate: Double
    private var ring: [Double]
    private var head = 0
    /// Samples pushed since the start. The clock.
    public private(set) var count = 0

    public init(rate: Double, seconds: Double = 8) {
        self.rate = rate
        ring = Array(repeating: 0, count: max(Int(rate * seconds), 16))
    }

    /// The tracker's clock at the newest sample, in seconds.
    public var now: Double { Double(max(count - 1, 0)) / rate }

    public mutating func push(_ value: Double) {
        ring[head] = value
        head = (head + 1) % ring.count
        count += 1
    }

    /// The newest `n` samples, oldest first.
    private func recent(_ n: Int) -> [Double] {
        (0..<n).map { ring[(head - n + $0 + ring.count * 2) % ring.count] }
    }

    public func estimate(minBPM: Double = 60, maxBPM: Double = 180,
                         minSeconds: Double = 4) -> Beat? {
        let n = min(count, ring.count)
        guard Double(n) >= rate * minSeconds else { return nil }

        // Keep only what stands above the average — the onsets — then take the
        // mean out again, so correlation measures shared *shape*. Without the
        // second step any non-negative signal, noise included, correlates with
        // itself at every lag.
        let raw = recent(n)
        let rawMean = raw.reduce(0, +) / Double(n)
        let x = raw.map { max($0 - rawMean, 0) }
        let xMean = x.reduce(0, +) / Double(n)
        let y = x.map { $0 - xMean }
        let variance = y.reduce(0) { $0 + $1 * $1 } / Double(n)
        guard variance > 1e-12 else { return nil }

        func r(_ lag: Int) -> Double {
            guard lag > 0, lag < n else { return 0 }
            var s = 0.0
            for i in lag..<n { s += y[i] * y[i - lag] }
            return s / Double(n - lag) / variance
        }

        let lo = max(Int((rate * 60 / maxBPM).rounded(.down)), 2)
        let hi = min(Int((rate * 60 / minBPM).rounded(.up)), n / 2 - 1)
        guard hi > lo + 2 else { return nil }
        var acf = [Double](repeating: 0, count: hi + 2)
        for lag in (lo - 1)...(hi + 1) { acf[lag] = r(lag) }

        var best = lo, bestScore = -Double.infinity
        for lag in lo...hi {
            let octaves = log2(60 * rate / Double(lag) / 120)
            let prior = exp(-0.5 * octaves * octaves)          // σ = one octave
            let score = prior * (acf[lag] + 0.5 * max(r(2 * lag), 0))
            if score > bestScore { bestScore = score; best = lag }
        }

        // Parabolic fit through the peak and its neighbours: the true period
        // is rarely a whole number of samples, and at ~94 samples a second a
        // whole-sample period is up to 1.5% out — a beat's drift every bar.
        let a = acf[best - 1], b = acf[best], c = acf[best + 1]
        let denom = a - 2 * b + c
        let shift = abs(denom) > 1e-12 ? min(max(0.5 * (a - c) / denom, -0.5), 0.5) : 0
        let lag = Double(best) + shift

        // Phase: the offset whose comb of beats, newest weighted most, lands on
        // the most onset energy. Neighbouring samples count half, so a beat
        // that falls between two samples is not missed.
        var bestPhase = 0, bestSum = -1.0
        for phase in 0..<max(Int(lag.rounded()), 1) {
            var sum = 0.0, k = 0.0, w = 1.0
            while true {
                let i = Int((Double(n - 1 - phase) - k * lag).rounded())
                guard i >= 1 else { break }
                sum += w * (x[i] + 0.5 * (x[i - 1] + (i + 1 < n ? x[i + 1] : 0)))
                k += 1
                w *= 0.85
            }
            if sum > bestSum { bestSum = sum; bestPhase = phase }
        }

        return Beat(period: lag / rate,
                    lastBeat: Double(count - 1 - bestPhase) / rate,
                    confidence: max(b, 0))
    }
}

/// Smooths a stream of `TempoTracker` estimates into a beat grid steady
/// enough to draw on.
///
/// Raw estimates wobble, and now and then flip an octave when a bar is all
/// hi-hat. Drawn directly, the light would stutter. So: a tempo is trusted
/// only once it repeats; a small change nudges the grid rather than
/// replacing it; a half or double reading is treated as the same pulse; and a
/// genuinely new tempo (the next song) has to hold for a few readings before
/// it takes over.
public struct BeatFollower: Sendable {
    /// Seconds per beat, or nil while no steady pulse has been heard.
    public private(set) var period: Double?
    /// A beat time on the tracker's clock; beats fall at `anchor + k·period`.
    public private(set) var anchor: Double = 0

    public var minConfidence = 0.15

    private var candidate: Double?
    private var agreements = 0
    private var misses = 0

    public init() {}

    public mutating func update(_ beat: TempoTracker.Beat?) {
        guard let beat, beat.confidence >= minConfidence else {
            misses += 1
            if misses >= 4 { period = nil; candidate = nil; agreements = 0 }
            return
        }
        misses = 0

        if let p = period {
            let ratio = beat.period / p
            if abs(ratio - 1) < 0.05 {
                period = p * 0.8 + beat.period * 0.2
                nudge(towards: beat.lastBeat, gain: 0.35)
                candidate = nil
                agreements = 0
                return
            }
            if abs(ratio - 2) < 0.1 { nudge(towards: beat.lastBeat, gain: 0.2) }
        }

        if let c = candidate, abs(beat.period / c - 1) < 0.05 {
            agreements += 1
        } else {
            candidate = beat.period
            agreements = 1
        }
        if agreements >= needed(for: beat.period) {
            period = beat.period
            anchor = beat.lastBeat
            candidate = nil
            agreements = 0
        }
    }

    /// How many readings in a row a tempo needs before it replaces ours.
    ///
    /// Half, double, and the 3:2 of a triplet feel are usually the same song
    /// heard at another level — measured on a 128 BPM track, readings of 64
    /// and 84 turned up between the right ones — so they need a long run, not
    /// the three a genuinely new tempo does. Long rather than never: the next
    /// song can be at exactly half the tempo.
    private func needed(for p: Double) -> Int {
        guard let current = period else { return 2 }
        let ratio = p / current
        let related = [2, 0.5, 1.5, 2.0 / 3].contains { abs(ratio / $0 - 1) < 0.05 }
        return related ? 8 : 3
    }

    /// Moves the grid part of the way towards a heard beat. Never more than
    /// half a beat, since the nearest predicted beat is the one corrected.
    private mutating func nudge(towards t: Double, gain: Double) {
        guard let p = period else { return }
        let predicted = anchor + ((t - anchor) / p).rounded() * p
        anchor = predicted + gain * (t - predicted)
    }
}
