import Foundation

/// Which gain law a blend should follow.
///
/// The choice is not cosmetic — it depends on whether the two signals are
/// related to each other.
public enum BlendCurve: String, Sendable {

    /// For *uncorrelated* material: two different songs. Their powers add, so
    /// holding `gainA² + gainB² = 1` keeps perceived loudness flat. Two linear
    /// ramps would both sit at 0.5 halfway and sum to 0.707 of full power — an
    /// audible ~3 dB sag right in the middle.
    case equalPower

    /// For *correlated* material: two players carrying the same track at the
    /// same position. Identical aligned audio sums by amplitude, so equal-power
    /// is exactly wrong here — `cos + sin` peaks at √2, a +3 dB lift. A linear
    /// pair keeps a coherent sum flat.
    case linear

    /// Equal-power, but with the outgoing track pulled down harder.
    ///
    /// Plain equal-power leaves both songs at 0.707 — −3 dB — through the whole
    /// middle of the blend, so for several seconds neither is in front and the
    /// overlap reads as two records playing at once. Raising the outgoing gain
    /// to a power steepens its fall (−4.8 dB at the midpoint at the default
    /// exponent) and the incoming gain is then *derived* from it rather than
    /// chosen, so `out² + into² = 1` still holds exactly and the combined
    /// loudness stays flat. The new track is simply in front sooner.
    case duckedPower

    /// A DJ switch. The new song sneaks in underneath — up to about −10 dB,
    /// never in front — while the old one carries on, easing back a touch in
    /// the last quarter. At the end both change at once: the old song is gone
    /// and the new one is at full, on the downbeat. Not power-preserving on
    /// purpose; the jump in the new song's level *is* the switch.
    case switchCut

    /// How hard `duckedPower` leans on the outgoing track. 1 is plain
    /// equal-power; higher ducks harder. Past about 2.5 the outgoing track
    /// drops away so fast that the overlap stops sounding like a blend.
    public static let duckExponent: Double = 1.6

    /// Outgoing and incoming gains at `t` in 0…1.
    public func gains(at t: Double) -> (out: Double, into: Double) {
        let x = min(max(t, 0), 1)
        switch self {
        case .equalPower: return (cos(x * .pi / 2), sin(x * .pi / 2))
        case .linear:     return (1 - x, x)
        case .switchCut:
            if x >= 1 { return (0, 1) }
            let rise = min(max((x - 0.1) / 0.6, 0), 1)
            let into = 0.32 * rise * rise * (3 - 2 * rise)
            let out = 1 - 0.12 * max(0, (x - 0.75) / 0.25)
            return (out, into)
        case .duckedPower:
            let out = pow(cos(x * .pi / 2), Self.duckExponent)
            // Derived, not picked: whatever the outgoing gain is, this is the
            // incoming gain that keeps the total power at exactly 1.
            return (out, (1 - out * out).squareRoot())
        }
    }

    /// Combined level the listener hears, given how the two signals relate.
    /// Should stay at 1 across the whole blend when the curve matches the
    /// material — this is what the unit tests assert.
    public func combined(at t: Double, correlated: Bool) -> Double {
        let (out, into) = gains(at: t)
        return correlated ? out + into : (out * out + into * into).squareRoot()
    }
}

/// Low-end handling across a blend.
///
/// Two full-range tracks overlapping both carrying bass is the single most
/// common way a mix turns to mud: the low frequencies are where most of the
/// energy is, and two uncorrelated bass lines sum into something boomy and
/// undefined. The fix DJs use is to keep the incoming track's low end pulled
/// down until the outgoing one has left, then hand the bottom over.
public struct BassSwap: Equatable, Sendable {

    /// Fraction of the blend where the outgoing low end starts leaving.
    public var outgoingStart: Double
    /// Fraction where the outgoing low end is gone.
    public var outgoingEnd: Double
    /// Fraction where the incoming low end starts arriving.
    public var incomingStart: Double
    /// Fraction where the incoming low end is fully in.
    public var incomingEnd: Double

    public init(outgoingStart: Double = 0.20, outgoingEnd: Double = 0.55,
                incomingStart: Double = 0.45, incomingEnd: Double = 0.80) {
        self.outgoingStart = outgoingStart
        self.outgoingEnd = outgoingEnd
        self.incomingStart = incomingStart
        self.incomingEnd = incomingEnd
    }

    /// Linear gains, 0…1, to apply to a low shelf on each side.
    public func gains(at t: Double) -> (outgoingBass: Double, incomingBass: Double) {
        (1 - ramp(t, from: outgoingStart, to: outgoingEnd),
         ramp(t, from: incomingStart, to: incomingEnd))
    }

    /// Total low-end energy through the blend. Never wildly above 1, which is
    /// the whole point of staggering the two ramps.
    public func combinedBass(at t: Double) -> Double {
        let g = gains(at: t)
        return g.outgoingBass + g.incomingBass
    }

    private func ramp(_ t: Double, from a: Double, to b: Double) -> Double {
        guard b > a else { return t >= b ? 1 : 0 }
        return min(max((t - a) / (b - a), 0), 1)
    }
}
