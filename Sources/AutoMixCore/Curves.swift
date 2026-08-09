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

    /// Outgoing and incoming gains at `t` in 0…1.
    public func gains(at t: Double) -> (out: Double, into: Double) {
        let x = min(max(t, 0), 1)
        switch self {
        case .equalPower: return (cos(x * .pi / 2), sin(x * .pi / 2))
        case .linear:     return (1 - x, x)
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
