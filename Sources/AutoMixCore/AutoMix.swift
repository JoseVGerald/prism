import Foundation

/// What is known about a track. Every musical field is optional, because most
/// of the time most of them are unknown, and the planner has to degrade rather
/// than guess.
public struct TrackAnalysis: Equatable, Sendable {
    public let id: String
    public let duration: TimeInterval
    public var bpm: Double?
    public var key: MusicalKey?
    /// 0…1. Loudness is the only honest proxy available without decoded audio.
    public var energy: Double?
    /// Seconds of intro before the track proper begins, when known.
    public var introEnd: TimeInterval?
    /// Where the outro begins, when known.
    public var outroStart: TimeInterval?
    /// 0…1 confidence in the numeric fields above.
    public var confidence: Double

    public init(id: String, duration: TimeInterval, bpm: Double? = nil,
                key: MusicalKey? = nil, energy: Double? = nil,
                introEnd: TimeInterval? = nil, outroStart: TimeInterval? = nil,
                confidence: Double = 0) {
        self.id = id
        self.duration = duration
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.introEnd = introEnd
        self.outroStart = outroStart
        self.confidence = confidence
    }
}

/// What the host player can actually do.
///
/// This exists because a plan is worthless if the pipeline cannot execute it.
/// Prism drives a YouTube web player: it can change volume and seek, and that
/// is the whole instruction set. It cannot time-stretch and it cannot filter,
/// so it declares that here and the planner produces something it can honour
/// instead of something that reads well and silently does nothing.
public struct MixCapabilities: Sendable {
    public var canTimeStretch: Bool
    public var canFilter: Bool
    public var canSeekIncoming: Bool
    /// How long the pipeline stalls when the playback rate changes.
    ///
    /// Not every host can retune for free. The web player freezes its media
    /// clock for roughly half a second on *any* rate change, so a plan made for
    /// it has to spend those changes sparingly and hide them; a host with real
    /// audio access pays nothing and can glide continuously. The planner needs
    /// to know which it is talking to.
    public var rateChangeCost: TimeInterval

    public init(canTimeStretch: Bool, canFilter: Bool, canSeekIncoming: Bool,
                rateChangeCost: TimeInterval = 0) {
        self.canTimeStretch = canTimeStretch
        self.canFilter = canFilter
        self.canSeekIncoming = canSeekIncoming
        self.rateChangeCost = rateChangeCost
    }

    /// A pipeline with real audio access.
    public static let full = MixCapabilities(canTimeStretch: true, canFilter: true,
                                             canSeekIncoming: true)
    /// Two web players and a volume control, with no way to retune at all.
    public static let volumeAndSeekOnly = MixCapabilities(canTimeStretch: false, canFilter: false,
                                                          canSeekIncoming: true)
    /// What Prism actually has: two YouTube players that *can* time-stretch
    /// with pitch preserved, but charge about 500 ms of frozen audio for every
    /// rate change, and cannot filter.
    public static let webPlayer = MixCapabilities(canTimeStretch: true, canFilter: false,
                                                  canSeekIncoming: true, rateChangeCost: 0.5)
}

public struct TransitionPlan: Equatable, Sendable {
    public var duration: TimeInterval
    /// Phrase length the duration came from, or nil for a plain timed fade.
    public var beats: Int?
    public var curve: BlendCurve
    /// Rate for the incoming track. Always 1 when the host cannot time-stretch.
    public var playbackRateForIncoming: Double
    public var bassSwap: BassSwap?
    /// Where to start the incoming track, to skip a long intro.
    public var startOffsetForIncoming: TimeInterval
    public var harmonic: HarmonicRelation?
    /// The tempo glide, when the two tracks can be brought together.
    public var tempoRamp: TempoRamp?
    public var confidence: Double
    /// Human-readable trail of why this plan looks the way it does.
    public var notes: [String]

    /// The safe answer: a plain timed equal-power crossfade.
    public static func fallback(seconds: TimeInterval, reason: String) -> TransitionPlan {
        TransitionPlan(duration: seconds, beats: nil, curve: .equalPower,
                       playbackRateForIncoming: 1, bassSwap: nil,
                       startOffsetForIncoming: 0, harmonic: nil, tempoRamp: nil,
                       confidence: 0, notes: [reason])
    }
}

public enum AutoMix {

    /// Minimum confidence in the analysis before it is allowed to change
    /// anything. Below this the plan is a plain timed crossfade.
    public static let confidenceFloor = 0.5

    /// Shortest blend any transition is allowed to be.
    ///
    /// A mix needs room to be a mix. Under about six seconds the two tracks
    /// barely coexist and the result reads as a quick fade rather than a
    /// transition, and there is no space to hide a tempo bend inside it. Every
    /// path through the planner respects this, including the fallbacks — the
    /// only thing that can shorten a blend is genuinely running out of track.
    public static let minimumDuration: TimeInterval = 6

    /// The plan for when the analysis is missing or untrusted.
    ///
    /// Still a plain equal-power crossfade of the full length — nothing here
    /// pretends to know something it does not. The one addition is the
    /// stylistic lean, which needs no tempo at all, so the transition keeps its
    /// lead-in on the great majority of real music that no free catalogue has
    /// ever measured. Confidence stays 0, because it should.
    private static func degraded(_ seconds: TimeInterval, _ reason: String,
                                 _ capabilities: MixCapabilities,
                                 _ bendShare: Double) -> TransitionPlan {
        var plan = TransitionPlan.fallback(seconds: seconds, reason: reason)
        guard capabilities.canTimeStretch, bendShare > 0,
              let ramp = TempoRampPlanner.stylistic(
                blendDuration: seconds, rateChangeCost: capabilities.rateChangeCost)
        else { return plan }

        plan.tempoRamp = ramp
        plan.notes.append(String(format: "no tempo to match, easing out %.1f%% into the mix",
                                 (1 - ramp.outgoingRate) * 100))
        return plan
    }

    /// Builds a transition from A to B.
    ///
    /// Every branch that cannot be justified falls back rather than guessing:
    /// unknown tempo, low confidence, or a tempo pair too far apart to reconcile
    /// all produce the plain timed crossfade the user asked for — never a
    /// shorter one, and never a fabricated tempo match.
    public static func plan(from a: TrackAnalysis,
                            to b: TrackAnalysis,
                            preferred: TimeInterval,
                            capabilities: MixCapabilities = .volumeAndSeekOnly,
                            maxDuration: TimeInterval = 16,
                            minimumDuration: TimeInterval = AutoMix.minimumDuration,
                            bendShare: Double = 0.5) -> TransitionPlan {

        // Running out of track is the one excuse for going under the floor, so
        // the floor itself is capped by what is actually available.
        let floor = min(minimumDuration, maxDuration)
        let base = max(preferred, floor)

        guard let bpmA = a.bpm, let bpmB = b.bpm, bpmA > 0, bpmB > 0 else {
            return degraded(base, "no tempo for one or both tracks", capabilities, bendShare)
        }
        guard min(a.confidence, b.confidence) >= confidenceFloor else {
            return degraded(base, "analysis confidence too low", capabilities, bendShare)
        }

        var notes: [String] = []
        let match = Tempo.match(from: bpmA, to: bpmB)
        notes.append(String(format: "%.1f → %.1f BPM, rate %.3f%@",
                            bpmA, bpmB, match.rate,
                            match.foldedOctave ? " (half/double time)" : ""))

        let harmonic: HarmonicRelation? = {
            guard let ka = a.key, let kb = b.key else { return nil }
            let r = Harmony.relation(from: ka, to: kb)
            notes.append("\(ka.camelot) → \(kb.camelot): \(r.rawValue)")
            return r
        }()

        let energyDelta = (b.energy ?? 0.5) - (a.energy ?? 0.5)
        // Grow the phrase rather than stretch a short one: a mix should land on
        // a musical boundary, so reaching the six-second floor by doubling
        // 8 beats to 16 keeps it musical where simply padding the time would
        // leave the blend ending mid-phrase.
        let beats = Tempo.phraseBeats(match: match, harmonic: harmonic,
                                      energyDelta: energyDelta,
                                      atLeast: floor, bpm: bpmA)

        // The phrase is counted at the outgoing track's tempo, since that is
        // the pulse the listener is already following.
        var duration = Tempo.duration(beats: beats, bpm: bpmA)
        notes.append(String(format: "%d beats at %.1f BPM = %.2fs", beats, bpmA, duration))

        // Never longer than what is left of A, never absurd, never under the
        // floor. The floor comes last so nothing can undercut it.
        duration = min(max(duration, 1), maxDuration)
        if duration < floor {
            duration = floor
            notes.append(String(format: "held to the %.0fs minimum", floor))
        }

        // Only promise a stretch the host can perform.
        var rate = 1.0
        if capabilities.canTimeStretch, match.acceptable, !match.foldedOctave || match.rate != 1 {
            rate = match.rate
        } else if !capabilities.canTimeStretch {
            notes.append("no time-stretch available; tempos left as they are")
        } else if !match.acceptable {
            notes.append(String(format: "stretch of %.1f%% too large; not beat-matching",
                                match.percentChange))
        }

        // The glide. Both tracks lean towards a shared tempo so the beats line
        // up through the overlap instead of walking over each other.
        var ramp: TempoRamp?
        if capabilities.canTimeStretch {
            ramp = TempoRampPlanner.plan(outgoingBPM: bpmA, incomingBPM: bpmB,
                                         match: match, blendDuration: duration,
                                         bendShare: bendShare,
                                         rateChangeCost: capabilities.rateChangeCost)
            if let ramp {
                notes.append(String(format:
                    "tempo glide: meet at %.1f BPM (out ×%.4f in %d steps, in ×%.4f)",
                    ramp.meetingBPM, ramp.outgoingRate, ramp.outgoingSteps.count,
                    ramp.incomingRate))
                // The ramp is the authority on the incoming rate: it is the one
                // that accounts for how much of the gap the outgoing track
                // actually absorbed, and both sides must agree or the beats
                // drift apart during the very overlap this exists to align.
                rate = ramp.incomingRate
            } else {
                notes.append("tempos too far apart to meet within budget; no glide")
            }
        }

        let swap = capabilities.canFilter ? BassSwap() : nil
        if !capabilities.canFilter { notes.append("no filtering available; no bass swap") }

        // Skipping a long intro puts the incoming track's body under the blend
        // instead of its empty opening.
        var offset: TimeInterval = 0
        if capabilities.canSeekIncoming, let intro = b.introEnd, intro > 1, intro < b.duration / 3 {
            offset = intro
            notes.append(String(format: "starting B at %.1fs to clear its intro", intro))
        }

        let confidence = min(a.confidence, b.confidence)
            * (match.acceptable ? 1 : 0.7)
            * (harmonic?.score ?? 0.8)

        return TransitionPlan(duration: duration, beats: beats, curve: .equalPower,
                              playbackRateForIncoming: rate, bassSwap: swap,
                              startOffsetForIncoming: offset, harmonic: harmonic,
                              tempoRamp: ramp, confidence: confidence, notes: notes)
    }
}
