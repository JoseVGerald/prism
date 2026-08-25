import Foundation

/// A tempo glide that carries one track into the next.
///
/// Two tracks at different tempos crossfaded together produce two pulses at
/// once, which is what a plain crossfade between rhythmic music sounds like:
/// the beats walk over each other. Bending both towards a common tempo before
/// they overlap is what makes a transition read as a *mix* rather than as one
/// song being turned down while another is turned up.
///
/// ## Why the ramp is stepped and not smooth
///
/// The obvious implementation — nudge `playbackRate` every frame so the tempo
/// slides continuously — does not work on this pipeline. Measured on the real
/// player: **every change to `playbackRate` freezes the media clock for roughly
/// 350–500 ms**, and the cost is flat. A 0.5 % nudge costs the same as a 5 %
/// one, and turning `preservesPitch` off only brings 510 ms down to 370 ms.
/// Stepping every 250 ms froze playback outright — the clock sat at 92.9 s for
/// three solid seconds while the wall clock ran on, because the pipeline never
/// got long enough between flushes to make progress.
///
/// So a rate change is not a free parameter to be automated; it is an expensive
/// event that has to be *hidden*. This type's job is to place a small number of
/// them where nobody can hear them:
///
/// * The **incoming** track is set once, while it is still paused and silent.
///   A rate set while paused survives both the seek and the play that follow,
///   so beat-matching the track that is arriving costs nothing at all. This is
///   where most of the tempo difference gets absorbed.
/// * The **outgoing** track bends in two or three steps placed late in the
///   blend, where its own gain is below about −5 dB and the incoming track is
///   roughly 3 dB louder and masking it. This is the part the listener is meant
///   to notice as the old song leaning into the new one.
///
/// The matched rate is then *abandoned* at the seam, and that is deliberate.
/// Loading a track resets the rate to 1 on its own, so the song the listener is
/// left with plays at its own true tempo — no deviation accumulates across a
/// playlist, and no freeze is ever spent on audible music to put it back. The
/// price is a small instantaneous tempo step exactly at the handover, which is
/// why the incoming budget is capped: a few percent stepping back to native,
/// underneath a blend, is far cheaper than half a second of dropout.
public struct TempoRamp: Equatable, Sendable {

    /// One scheduled rate change on the outgoing track.
    public struct Step: Equatable, Sendable {
        /// Where in the blend to apply it, as a fraction of the blend length.
        public let at: Double
        /// Rate to set at that point.
        public let rate: Double

        public init(at: Double, rate: Double) {
            self.at = at
            self.rate = rate
        }
    }

    /// Tempo the two tracks meet at, in BPM.
    public let meetingBPM: Double
    /// Rate the outgoing track finishes its bend on.
    public let outgoingRate: Double
    /// Rate the incoming track holds through the blend and keeps afterwards.
    public let incomingRate: Double
    /// The outgoing bend, in order. Empty when the outgoing track does not move.
    public let outgoingSteps: [Step]

    public init(meetingBPM: Double, outgoingRate: Double, incomingRate: Double,
                outgoingSteps: [Step]) {
        self.meetingBPM = meetingBPM
        self.outgoingRate = outgoingRate
        self.incomingRate = incomingRate
        self.outgoingSteps = outgoingSteps
    }

    /// How far either track is asked to bend, as a percentage.
    public var largestStretchPercent: Double {
        max(abs(outgoingRate - 1), abs(incomingRate - 1)) * 100
    }
}

public enum TempoRampPlanner {

    /// Furthest the *outgoing* track is allowed to bend. It is audible while it
    /// bends, so it still gets the tighter budget — but a bend nobody notices
    /// is not worth the freeze it costs, so this is deliberately past the point
    /// of being subtle. The old song audibly leans.
    public static let maxOutgoingPercent = 6.0

    /// Furthest the *incoming* track is allowed to bend.
    ///
    /// This is the generous one, and it can be, because of where the bend
    /// lands. The rate is set once while the track is still paused and silent,
    /// held across the blend, and released at the handover — so the only part
    /// of the new song played off its own tempo is its opening, underneath the
    /// old one, which is exactly the stretch a DJ pulls to drag a record onto
    /// the beat. It costs a tempo step at the seam, which is the price of
    /// bending this far and is why it is not larger still.
    public static let maxIncomingPercent = 12.0

    /// Window within the blend where an outgoing rate change is masked well
    /// enough to spend one. Before 0.60 the outgoing track is still too loud to
    /// hide a dropout in; after 0.94 there is not enough blend left for the
    /// pipeline to recover before the handover.
    public static let maskWindow: ClosedRange<Double> = 0.60...0.94

    /// Builds the glide, or returns nil when there is no honest way to make the
    /// two tempos meet inside the budgets above.
    ///
    /// - Parameters:
    ///   - bendShare: how much of the tempo gap the *outgoing* track should
    ///     absorb, 0…1. 0 is classic beat-matching, where only the incoming
    ///     track moves; 0.5 meets in the middle and is what makes the bend
    ///     audible as a lead-in.
    ///   - rateChangeCost: how long the pipeline stalls on a rate change.
    ///     Steps are spaced at least this far apart, so they never pile up.
    public static func plan(outgoingBPM: Double,
                            incomingBPM: Double,
                            match: TempoMatch,
                            blendDuration: TimeInterval,
                            bendShare: Double = 0.5,
                            rateChangeCost: TimeInterval = 0.5) -> TempoRamp? {

        guard outgoingBPM > 0, incomingBPM > 0, blendDuration > 0 else { return nil }

        // Count the incoming track at the outgoing track's octave. 170 against
        // 85 is one pulse, not a doubling, and asking for a 2× stretch there
        // would be rejected when in fact nothing needs to move.
        let foldedIncoming = foldToOctave(of: outgoingBPM, bpm: incomingBPM)
        guard foldedIncoming > 0 else { return nil }

        // Work in log space: rates compose by multiplication, so the "distance"
        // between two tempos is a difference of logarithms, and splitting it
        // evenly means splitting it there.
        let gap = log(foldedIncoming / outgoingBPM)

        // Already together — nothing to bend, and no reason to spend a freeze.
        if abs(gap) < log(1.001) {
            return TempoRamp(meetingBPM: outgoingBPM, outgoingRate: 1,
                             incomingRate: 1, outgoingSteps: [])
        }

        let outCap = log(1 + maxOutgoingPercent / 100)
        let inCap = log(1 + maxIncomingPercent / 100)

        // The outgoing track takes its share, the incoming track takes the
        // rest. `logIn = logOut - gap` holds the two effective tempos exactly
        // equal by construction, so alignment survives every clamp below.
        var logOut = gap * min(max(bendShare, 0), 1)
        logOut = min(max(logOut, -outCap), outCap)
        var logIn = logOut - gap

        // The incoming track cannot cover its share: give back as much as its
        // budget allows and ask the outgoing track for the remainder.
        if abs(logIn) > inCap {
            logIn = min(max(logIn, -inCap), inCap)
            logOut = logIn + gap
            // Neither side can stretch far enough. Beat-matching would be a
            // lie, so report none and let the caller crossfade plainly.
            guard abs(logOut) <= outCap else { return nil }
        }

        let outgoingRate = exp(logOut)
        let incomingRate = exp(logIn)
        let meeting = outgoingBPM * outgoingRate

        let steps = schedule(to: outgoingRate, blendDuration: blendDuration,
                             rateChangeCost: rateChangeCost)

        // A bend the outgoing track cannot actually be given — too short a
        // blend to fit even one masked step — still beat-matches, it just does
        // not lean in. Report the rate it will really run at rather than the
        // one that was wanted, or the caller would align against a fiction.
        guard let last = steps.last else {
            return TempoRamp(meetingBPM: outgoingBPM * 1, outgoingRate: 1,
                             incomingRate: exp(-gap), outgoingSteps: [])
        }

        return TempoRamp(meetingBPM: meeting, outgoingRate: last.rate,
                         incomingRate: incomingRate, outgoingSteps: steps)
    }

    /// Lays the outgoing bend out across the masked window.
    ///
    /// Steps are spaced by at least the pipeline's recovery time; crowding them
    /// is what froze playback outright in testing. Three is the ceiling — past
    /// that the bend is a series of dropouts rather than a lean.
    public static func schedule(to finalRate: Double,
                         blendDuration: TimeInterval,
                         rateChangeCost: TimeInterval) -> [TempoRamp.Step] {

        guard abs(finalRate - 1) > 1e-6 else { return [] }

        let window = maskWindow.upperBound - maskWindow.lowerBound
        let seconds = window * blendDuration
        let spacing = max(rateChangeCost * 1.8, 0.9)

        // How many fit, given each needs room to recover before the next.
        let fit = Int((seconds / spacing).rounded(.down)) + 1
        let count = min(max(fit, 0), 3)
        guard count > 0, seconds >= spacing * 0.5 else { return [] }

        return (1...count).map { i in
            let progress = Double(i) / Double(count)
            let at = count == 1
                ? maskWindow.lowerBound + window * 0.35
                : maskWindow.lowerBound + window * progress
            // Ease the bend so most of it lands late, where the outgoing track
            // is quietest and the change is best hidden.
            let eased = progress * progress
            return TempoRamp.Step(at: min(at, maskWindow.upperBound),
                                  rate: 1 + (finalRate - 1) * eased)
        }
    }

    /// How far a bend leans when there is no tempo to aim at. Big enough now to
    /// be plainly heard as the track easing off, while staying short of the
    /// point where it reads as a fault.
    public static let stylisticPercent = 4.0

    /// A lead-in for the overwhelmingly common case where nobody knows the
    /// tempo of either track.
    ///
    /// Tempo metadata is far patchier than it looks. Deezer — the only free
    /// source that still answers — returns `bpm: 0` for entire catalogues: it
    /// knows all thirteen tracks of the playlist this was tested against and
    /// has a tempo for none of them. Refusing to bend without a tempo would
    /// mean the feature never fires on most real music.
    ///
    /// So when there is nothing to beat-match *to*, the outgoing track still
    /// eases as it hands over. This cannot claim the beats will line up, and it
    /// does not pretend to: nothing is asked of the incoming track, and the
    /// plan's confidence stays at zero. It is the turntable slowing under the
    /// mix — an effect, honestly labelled, rather than a measurement.
    public static func stylistic(blendDuration: TimeInterval,
                                 rateChangeCost: TimeInterval = 0.5) -> TempoRamp? {
        let rate = 1 - stylisticPercent / 100
        let steps = schedule(to: rate, blendDuration: blendDuration,
                             rateChangeCost: rateChangeCost)
        guard let last = steps.last else { return nil }
        return TempoRamp(meetingBPM: 0, outgoingRate: last.rate,
                         incomingRate: 1, outgoingSteps: steps)
    }

    /// Brings `bpm` into the same octave as `reference`, so 170 counted against
    /// 85 becomes 85 rather than a doubling.
    public static func foldToOctave(of reference: Double, bpm: Double) -> Double {
        guard reference > 0, bpm > 0 else { return bpm }
        var folded = bpm
        while folded / reference > 1.4142 { folded /= 2 }
        while folded / reference < 0.7071 { folded *= 2 }
        return folded
    }
}
