import Foundation
import AutoMixCore

// Tests for AutoMixCore.
//
// A hand-rolled harness rather than XCTest or swift-testing: `swift test` on
// macOS needs Xcode's XCTest runner, and Xcode is unusable on this machine
// (unaccepted licence). This runs anywhere a Swift toolchain does.
//
//     swift run AutoMixTests

var failures: [String] = []
var checks = 0
var currentSuite = ""

@MainActor func suite(_ name: String) {
    currentSuite = name
    print("\n\u{001B}[1m\(name)\u{001B}[0m")
}

@MainActor func check(_ condition: Bool, _ description: String) {
    checks += 1
    if condition {
        print("  ✓ \(description)")
    } else {
        print("  ✗ \(description)")
        failures.append("\(currentSuite): \(description)")
    }
}

func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - Camelot wheel

suite("Camelot wheel")

check(MusicalKey(pitchClass: 0, mode: .major).camelot == "8B", "C major is 8B")
check(MusicalKey(pitchClass: 9, mode: .minor).camelot == "8A", "A minor is 8A")
check(MusicalKey(pitchClass: 7, mode: .major).camelot == "9B", "G major is 9B")
check(MusicalKey(pitchClass: 11, mode: .major).camelot == "1B", "B major is 1B")

var roundTripped = true
for pc in 0..<12 {
    for mode in [MusicalKey.Mode.major, .minor] {
        let key = MusicalKey(pitchClass: pc, mode: mode)
        if MusicalKey(camelot: key.camelot) != key { roundTripped = false }
    }
}
check(roundTripped, "every key survives a round trip through its Camelot code")

let allSlots = (0..<12).flatMap { pc in
    [MusicalKey(pitchClass: pc, mode: .major).camelot,
     MusicalKey(pitchClass: pc, mode: .minor).camelot]
}
check(Set(allSlots).count == 24, "all 24 slots are used exactly once")

check(MusicalKey(camelot: "13A") == nil, "rejects an out-of-range number")
check(MusicalKey(camelot: "0B") == nil, "rejects zero")
check(MusicalKey(camelot: "8C") == nil, "rejects an unknown letter")
check(MusicalKey(camelot: "") == nil, "rejects empty input")

let c = MusicalKey(camelot: "8B")!
check(Harmony.relation(from: c, to: c) == .identical, "a key against itself is identical")
check(Harmony.relation(from: c, to: MusicalKey(camelot: "8A")!) == .relative,
      "8B → 8A is the relative minor")
check(Harmony.relation(from: c, to: MusicalKey(camelot: "9B")!) == .adjacent,
      "8B → 9B is one step round the wheel")
check(Harmony.relation(from: c, to: MusicalKey(camelot: "7B")!) == .adjacent,
      "8B → 7B is one step the other way")
check(Harmony.relation(from: c, to: MusicalKey(camelot: "10B")!) == .energyBoost,
      "8B → 10B is the two-step lift")
check(Harmony.relation(from: c, to: MusicalKey(camelot: "2B")!) == .clash,
      "8B → 2B clashes")
check(Harmony.relation(from: c, to: MusicalKey(camelot: "9A")!) == .clash,
      "adjacent number on the other side of the wheel still clashes")
check(Harmony.relation(from: MusicalKey(camelot: "12B")!,
                       to: MusicalKey(camelot: "1B")!) == .adjacent,
      "the wheel wraps from 12 to 1")
check(Harmony.relation(from: MusicalKey(camelot: "1B")!,
                       to: MusicalKey(camelot: "12B")!) == .adjacent,
      "and back from 1 to 12")

// MARK: - Tempo

suite("Tempo")

let same = Tempo.match(from: 128, to: 128)
check(close(same.rate, 1, 1e-6) && same.acceptable && !same.foldedOctave,
      "identical tempos need no stretch")

let near = Tempo.match(from: 128, to: 124)
check(close(near.rate, 128.0 / 124.0, 1e-6) && near.acceptable && abs(near.percentChange) < 6,
      "a small gap is acceptable")

check(!Tempo.match(from: 130, to: 100).acceptable,
      "a 30% gap is rejected rather than forced")

let doubleTime = Tempo.match(from: 170, to: 85)
check(close(doubleTime.rate, 1, 1e-6) && doubleTime.foldedOctave && doubleTime.acceptable,
      "170 over 85 folds to no stretch at all")
let halfTime = Tempo.match(from: 85, to: 170)
check(close(halfTime.rate, 1, 1e-6) && halfTime.foldedOctave && halfTime.acceptable,
      "and 85 over 170 folds the same way")

let realPair = Tempo.match(from: 84.89, to: 103.88)
check(!realPair.acceptable && !realPair.foldedOctave,
      "a real Deezer pair 22% apart is not beat-matched")

check(!Tempo.match(from: 0, to: 120).acceptable, "zero tempo is never acceptable")
check(!Tempo.match(from: 120, to: 0).acceptable, "and neither is a zero target")

check(close(Tempo.beatDuration(bpm: 120), 0.5), "120 BPM is half a second per beat")
check(close(Tempo.duration(beats: 8, bpm: 120), 4), "8 beats at 120 BPM is 4 seconds")
check(close(Tempo.duration(beats: 16, bpm: 96), 10), "16 beats at 96 BPM is 10 seconds")

let poorMatch = TempoMatch(rate: 1.3, foldedOctave: false, acceptable: false)
check(Tempo.phraseBeats(match: poorMatch, harmonic: nil, energyDelta: 0) == 4,
      "a poor tempo match gets the shortest phrase")
let goodMatch = TempoMatch(rate: 1.005, foldedOctave: false, acceptable: true)
check(Tempo.phraseBeats(match: goodMatch, harmonic: .identical, energyDelta: 0) == 16,
      "a tight match in the same key gets 16 beats")
check(Tempo.phraseBeats(match: goodMatch, harmonic: .clash, energyDelta: 0) == 4,
      "a clashing key never gets a long overlap")
check(Tempo.phraseBeats(match: goodMatch, harmonic: .identical, energyDelta: 0.6) == 8,
      "a big loudness jump shortens the phrase")

// MARK: - Blend curves

suite("Blend curves")

var equalPowerFlat = true
var linearFlat = true
for i in 0...100 {
    let t = Double(i) / 100
    if !close(BlendCurve.equalPower.combined(at: t, correlated: false), 1) { equalPowerFlat = false }
    if !close(BlendCurve.linear.combined(at: t, correlated: true), 1) { linearFlat = false }
}
check(equalPowerFlat, "equal-power holds power flat across two different songs")
check(linearFlat, "linear holds level flat across two copies of the same song")

check(close(BlendCurve.equalPower.combined(at: 0.5, correlated: true), 2.0.squareRoot()),
      "equal-power on identical audio lifts to √2 — the +3 dB seam bug")
check(close(BlendCurve.linear.combined(at: 0.5, correlated: false), 0.7071, 1e-4),
      "linear on different songs sags to 0.707 — the 3 dB hole")

// Ducking the outgoing track must not cost loudness: the incoming gain is
// derived from the outgoing one precisely so the sum stays flat.
var duckedFlat = true
for i in 0...100 {
    let t = Double(i) / 100
    if !close(BlendCurve.duckedPower.combined(at: t, correlated: false), 1) { duckedFlat = false }
}
check(duckedFlat, "ducked power still holds the combined loudness flat")

var duckedIsQuieter = true
for i in 1...99 {
    let t = Double(i) / 100
    let ducked = BlendCurve.duckedPower.gains(at: t)
    let plain = BlendCurve.equalPower.gains(at: t)
    if ducked.out >= plain.out { duckedIsQuieter = false }
    if ducked.into <= plain.into { duckedIsQuieter = false }
}
check(duckedIsQuieter,
      "the outgoing track is quieter, and the incoming one louder, everywhere inside the blend")

check(BlendCurve.duckedPower.gains(at: 0.5).out < 0.6,
      "the old track is more than 3 dB down by the midpoint, not parked at 0.707")

var endpointsClean = true
for curve in [BlendCurve.equalPower, .linear, .duckedPower] {
    if !close(curve.gains(at: 0).out, 1) { endpointsClean = false }
    if !close(curve.gains(at: 0).into, 0) { endpointsClean = false }
    if !close(curve.gains(at: 1).out, 0) { endpointsClean = false }
    if !close(curve.gains(at: 1).into, 1) { endpointsClean = false }
}
check(endpointsClean, "every curve starts and ends cleanly")
check(close(BlendCurve.linear.gains(at: -5).out, 1)
      && close(BlendCurve.linear.gains(at: 5).into, 1),
      "gains clamp outside 0…1")

let swap = BassSwap()
check(close(swap.gains(at: 0).outgoingBass, 1) && close(swap.gains(at: 0).incomingBass, 0),
      "the outgoing track owns the low end at the start")
check(close(swap.gains(at: 1).outgoingBass, 0) && close(swap.gains(at: 1).incomingBass, 1),
      "and the incoming track owns it at the end")

var bassNeverStacks = true
for i in 0...100 where BassSwap().combinedBass(at: Double(i) / 100) > 1.35 {
    bassNeverStacks = false
}
check(bassNeverStacks, "the two low ends never stack up into mud")

let early = swap.gains(at: 0.25)
check(early.outgoingBass > 0.8 && close(early.incomingBass, 0),
      "a quarter in, the incoming low end is still held down")

// MARK: - Transition planning

suite("Transition planning")

@MainActor func track(_ id: String, bpm: Double?, key: String? = nil, energy: Double? = nil,
           confidence: Double = 1, duration: TimeInterval = 200,
           introEnd: TimeInterval? = nil) -> TrackAnalysis {
    TrackAnalysis(id: id, duration: duration, bpm: bpm,
                  key: key.flatMap(MusicalKey.init(camelot:)),
                  energy: energy, introEnd: introEnd, confidence: confidence)
}

let noTempo = AutoMix.plan(from: track("a", bpm: nil), to: track("b", bpm: 120), preferred: 6)
check(noTempo.duration == 6 && noTempo.beats == nil && noTempo.curve == .equalPower
      && noTempo.confidence == 0,
      "no tempo falls back to the plain timed fade")

let lowConfidence = AutoMix.plan(from: track("a", bpm: 120, confidence: 0.2),
                                 to: track("b", bpm: 120, confidence: 0.2), preferred: 7)
check(lowConfidence.duration == 7 && lowConfidence.beats == nil,
      "untrusted analysis falls back too")

let matched = AutoMix.plan(from: track("a", bpm: 120, key: "8A", energy: 0.5),
                           to: track("b", bpm: 120, key: "8A", energy: 0.5), preferred: 6)
check(matched.beats == 16 && close(matched.duration, 8, 1e-6) && matched.harmonic == .identical,
      "a matched pair gets 16 beats at the outgoing tempo — 8 seconds")

let clashing = AutoMix.plan(from: track("a", bpm: 120, key: "8A", energy: 0.5),
                            to: track("b", bpm: 120, key: "2B", energy: 0.5), preferred: 6)
check(clashing.harmonic == .clash && clashing.beats == 4 && close(clashing.duration, 6, 1e-6),
      "clashing keys stay a 4-beat idea but still get the six-second floor")

let limited = AutoMix.plan(from: track("a", bpm: 128), to: track("b", bpm: 124),
                           preferred: 6, capabilities: .volumeAndSeekOnly)
check(limited.playbackRateForIncoming == 1 && limited.bassSwap == nil
      && limited.notes.contains { $0.contains("no time-stretch") },
      "never promises a stretch or a filter the host cannot perform")

let full = AutoMix.plan(from: track("a", bpm: 128), to: track("b", bpm: 124),
                        preferred: 6, capabilities: .full)
check(full.bassSwap != nil && full.tempoRamp != nil,
      "uses stretch and filtering when the host has them")
// The invariant that matters is not the incoming rate on its own but that the
// two tracks end up at the *same* tempo — the outgoing one has moved too.
check(full.tempoRamp.map { close(128 * $0.outgoingRate, 124 * $0.incomingRate, 1e-6) } == true,
      "both tracks are bent to one shared tempo")

let absurd = AutoMix.plan(from: track("a", bpm: 90), to: track("b", bpm: 140),
                          preferred: 6, capabilities: .full)
check(absurd.playbackRateForIncoming == 1 && absurd.notes.contains { $0.contains("too large") },
      "refuses to stretch across an absurd gap")

let withIntro = AutoMix.plan(from: track("a", bpm: 120),
                             to: track("b", bpm: 120, duration: 240, introEnd: 12),
                             preferred: 6)
check(close(withIntro.startOffsetForIncoming, 12), "skips a long intro when it can seek")

let slow = AutoMix.plan(from: track("a", bpm: 20, key: "8A", energy: 0.5),
                        to: track("b", bpm: 20, key: "8A", energy: 0.5),
                        preferred: 6, maxDuration: 16)
check(slow.duration <= 16, "duration is clamped to something sane")

let folded = AutoMix.plan(from: track("a", bpm: 170, key: "8A", energy: 0.5),
                          to: track("b", bpm: 85, key: "8A", energy: 0.5),
                          preferred: 6, capabilities: .full)
check(close(folded.playbackRateForIncoming, 1, 1e-6)
      && folded.notes.contains { $0.contains("half/double time") },
      "a half-time pair counts as matched, not as a 2× stretch")

// MARK: - Six-second floor

suite("Minimum blend length")

let tiny = AutoMix.plan(from: track("a", bpm: nil), to: track("b", bpm: nil), preferred: 2)
check(close(tiny.duration, 6), "a 2s preference is lifted to the floor even with no analysis")

let fastPair = AutoMix.plan(from: track("a", bpm: 174, key: "8A", energy: 0.5),
                            to: track("b", bpm: 174, key: "8A", energy: 0.5), preferred: 3)
check(fastPair.duration >= 6, "a fast pair still gets at least six seconds")
check(fastPair.beats == 32,
      "the phrase is doubled to reach the floor rather than the time being padded")

// 16 beats at 174 BPM is 5.52s, under the floor; 32 beats is 11.03s. Growing
// the phrase is what keeps the blend landing on a bar line.
check(close(Tempo.duration(beats: 32, bpm: 174), fastPair.duration, 1e-6),
      "and the grown phrase is what sets the length")

let cramped = AutoMix.plan(from: track("a", bpm: 120), to: track("b", bpm: 120),
                           preferred: 6, maxDuration: 3)
check(cramped.duration <= 3,
      "running out of track is the one thing allowed to undercut the floor")

let noAnalysisFloor = AutoMix.plan(from: track("a", bpm: 120, confidence: 0.1),
                                   to: track("b", bpm: 120, confidence: 0.1), preferred: 1)
check(close(noAnalysisFloor.duration, 6), "the fallback path honours the floor too")

// MARK: - Tempo glide

suite("Tempo glide")

let glide = TempoRampPlanner.plan(outgoingBPM: 120, incomingBPM: 126,
                                  match: Tempo.match(from: 120, to: 126),
                                  blendDuration: 8)
check(glide != nil, "a 5% gap can be met")
if let g = glide {
    check(close(120 * g.outgoingRate, 126 * g.incomingRate, 1e-9),
          "both sides land on exactly one tempo")
    check(g.outgoingRate > 1 && g.incomingRate < 1,
          "the slower track speeds up while the faster one eases off")
    check(abs(g.outgoingRate - 1) * 100 <= TempoRampPlanner.maxOutgoingPercent + 1e-9,
          "the audible side stays inside the tighter budget")
    check(g.outgoingSteps.allSatisfy { TempoRampPlanner.maskWindow.contains($0.at) },
          "every step lands where the outgoing track is quiet enough to hide it")
    check(g.outgoingSteps.count <= 3, "never more than three dropouts spent on a bend")
    check(zip(g.outgoingSteps, g.outgoingSteps.dropFirst())
            .allSatisfy { ($1.at - $0.at) * 8 >= 0.9 },
          "steps are spaced far enough apart for the pipeline to recover")
    check(g.outgoingSteps.last.map { close($0.rate, g.outgoingRate, 1e-9) } == true,
          "the bend finishes on the rate the plan claims")
}

let sameTempo = TempoRampPlanner.plan(outgoingBPM: 128, incomingBPM: 128,
                                      match: Tempo.match(from: 128, to: 128),
                                      blendDuration: 8)
check(sameTempo?.outgoingSteps.isEmpty == true && sameTempo?.incomingRate == 1,
      "an identical pair spends no rate changes at all")

let halfTimeGlide = TempoRampPlanner.plan(outgoingBPM: 170, incomingBPM: 85,
                                     match: Tempo.match(from: 170, to: 85),
                                     blendDuration: 8)
check(halfTimeGlide?.outgoingSteps.isEmpty == true,
      "a half-time pair is already in step and needs no bend")

let impossible = TempoRampPlanner.plan(outgoingBPM: 90, incomingBPM: 140,
                                       match: Tempo.match(from: 90, to: 140),
                                       blendDuration: 8)
check(impossible == nil, "a gap neither side can cover reports no glide rather than a bad one")

// A blend too short to hide even one dropout must not try to bend the outgoing
// track — it would spend a freeze in the middle of audible music.
let crampedGlide = TempoRampPlanner.plan(outgoingBPM: 120, incomingBPM: 126,
                                         match: Tempo.match(from: 120, to: 126),
                                         blendDuration: 1.2)
check(crampedGlide?.outgoingSteps.isEmpty == true && crampedGlide?.outgoingRate == 1,
      "too short a blend beat-matches silently instead of bending audibly")
check(crampedGlide.map { close(120 * $0.outgoingRate, 126 * $0.incomingRate, 1e-9) } == true,
      "and the incoming rate still lands them on one tempo")

// Tempo data is missing far more often than not — 0 of 13 tracks on the
// playlist this was built against — so the no-analysis path is the one most
// listeners will actually hear.
let blind = AutoMix.plan(from: track("a", bpm: nil), to: track("b", bpm: nil),
                         preferred: 8, capabilities: .webPlayer)
check(blind.tempoRamp != nil, "a transition with no analysis still leans into the mix")
check(blind.confidence == 0 && blind.playbackRateForIncoming == 1,
      "but claims no confidence and asks nothing of the incoming track")
check(blind.tempoRamp.map { $0.outgoingRate < 1 && $0.outgoingRate > 0.95 } == true,
      "the lean is a gentle ease-off, not a lurch")

let blindNoStretch = AutoMix.plan(from: track("a", bpm: nil), to: track("b", bpm: nil),
                                  preferred: 8, capabilities: .volumeAndSeekOnly)
check(blindNoStretch.tempoRamp == nil,
      "and a host that cannot stretch is never handed a bend to perform")

let unbent = AutoMix.plan(from: track("a", bpm: nil), to: track("b", bpm: nil),
                          preferred: 8, capabilities: .webPlayer, bendShare: 0)
check(unbent.tempoRamp == nil, "turning the bend off removes it from the blind path too")

check(close(TempoRampPlanner.foldToOctave(of: 90, bpm: 140), 70),
      "140 counted against 90 folds to 70")
check(close(TempoRampPlanner.foldToOctave(of: 170, bpm: 85), 170),
      "85 counted against 170 folds up, not down")

// Long blends: a matching pair grows to the setting in whole bars.
let longA = TrackAnalysis(id: "a", duration: 240, bpm: 120, energy: 0.5, confidence: 0.9)
let longB = TrackAnalysis(id: "b", duration: 240, bpm: 120, energy: 0.5, confidence: 0.9)
let thirty = AutoMix.plan(from: longA, to: longB, preferred: 30, maxDuration: 30)
check(close(thirty.duration, 30, 0.01) && thirty.beats.map { $0 % 4 == 0 } == true,
      "a 30s setting gives a 30s blend on a bar line for a matching pair (got \(thirty.duration)s, \(thirty.beats ?? 0) beats)")
let short = AutoMix.plan(from: longA, to: longB, preferred: 6, maxDuration: 30)
check(short.duration < 10, "a short setting is not grown (got \(short.duration)s)")
let capped = AutoMix.plan(from: longA, to: longB, preferred: 30, maxDuration: 20)
check(capped.duration <= 20, "never longer than what is left of the song")

// MARK: - Lyric timing

suite("Lyric timing")

let lyricLines = [
    TimedLine(start: 10, text: "a unbelievable day"),
    TimedLine(start: 13, text: "second line"),
    TimedLine(start: 25, text: "after a long break"),
]

// Word windows tile the line exactly: no gap, no overlap, no overrun.
let windows = LyricTiming.wordWindows(in: lyricLines, line: 0)
let windowSum = windows.reduce(0) { $0 + $1.duration }
check(close(windowSum, LyricTiming.end(of: 0, in: lyricLines) - 10, 1e-9),
      "estimated word windows sum to the line's sung window")
check(close(windows[0].start, 10) && close(windows[1].start, windows[0].start + windows[0].duration),
      "word windows are contiguous from the line's start")
check(windows[1].duration > windows[0].duration * 5,
      "a long word is given longer than a one-letter word")

// Line boundaries clamp rather than running past 0 or 1.
let atStart = LyricTiming.moment(in: lyricLines, at: 10)
check(atStart.lineIndex == 0 && close(atStart.lineProgress, 0),
      "progress is 0 at the instant a line starts")
let late = LyricTiming.moment(in: lyricLines, at: 12.9)
check(late.lineIndex == 0 && close(late.lineProgress, 1) && late.wordProgress.allSatisfy { close($0, 1) },
      "progress clamps at 1 once the line's window is over")
check(LyricTiming.moment(in: lyricLines, at: 3).lineIndex == nil,
      "before the first line there is no current line")

// Instrumental gaps.
let inBreak = LyricTiming.moment(in: lyricLines, at: 20)
check(inBreak.lineIndex == 1 && inBreak.gap != nil,
      "a silence longer than the threshold is reported as a gap")
let shortPause = LyricTiming.moment(in: lyricLines, at: 12.9)
check(shortPause.gap == nil, "a 3-second pause between lines is not a gap")
let blankBreak = [TimedLine(start: 5, text: "sing"), TimedLine(start: 8, text: ""),
                  TimedLine(start: 14, text: "again")]
check(LyricTiming.moment(in: blankBreak, at: 10).gap != nil,
      "an empty stamped LRC line marks a break")

// Enhanced LRC.
let enhanced = LRC.parse("[00:10.00]<00:10.00>Hello <00:10.80>there <00:11.50>world")
check(enhanced.count == 1 && enhanced[0].text == "Hello there world",
      "word tags are stripped from the displayed text")
check(enhanced[0].wordStarts == [10.0, 10.8, 11.5],
      "enhanced LRC word times are kept")
let exactWindows = LyricTiming.wordWindows(in: enhanced, line: 0)
check(close(exactWindows[1].start, 10.8) && close(exactWindows[1].duration, 0.7, 1e-9),
      "exact word times are used instead of the estimate")

let partial = LRC.parse("[00:05.00]Hello <00:05.60>big world")
check(partial[0].text == "Hello big world" && partial[0].wordStarts == nil,
      "partial word stamps are dropped rather than half-trusted")

let repeated = LRC.parse("[00:10.00][01:10.00]<00:10.00>la <00:10.50>la")
check(repeated.count == 2 && repeated[1].wordStarts == [70.0, 70.5],
      "a repeated line shifts its word stamps to each occurrence")

let plain = LRC.parse("[ar:Someone]\n[00:01.50]first\n[00:03.00]second")
check(plain.map(\.start) == [1.5, 3.0] && plain.map(\.text) == ["first", "second"],
      "metadata tags are skipped and plain lines parse as before")

// Pacing: a line is sung up to the next one unless the next is far away.
let paced = [TimedLine(start: 10, text: "hold me closer now"), TimedLine(start: 13.5, text: "next")]
check(close(LyricTiming.end(of: 0, in: paced), 13.5 - LyricTiming.tail, 1e-9),
      "a line with the next 3.5s away fills right up to it, not to a length estimate")

// MARK: - Beat tracking

suite("Beat tracking")

let onsetRate = 93.75      // 48 kHz, 512-sample hop — what LiveAudio feeds it

/// Deterministic noise, so a failure is reproducible.
struct Noise {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

func clickTrack(bpm: Double, seconds: Double, offbeats: Double = 0,
                noise: Double = 0.05, seed: UInt64 = 1) -> (TempoTracker, lastBeat: Double) {
    var tracker = TempoTracker(rate: onsetRate)
    var rng = Noise(state: seed)
    let period = 60 / bpm
    let total = Int(seconds * onsetRate)
    var lastBeat = 0.0
    for i in 0..<total {
        let t = Double(i) / onsetRate
        let phase = (t + 0.13).truncatingRemainder(dividingBy: period) / period
        let dt = 1 / onsetRate / period
        var v = rng.next() * noise
        if phase < dt { v += 1; lastBeat = t }
        if offbeats > 0, abs(phase - 0.5) < dt / 2 { v += offbeats }
        tracker.push(v)
    }
    return (tracker, lastBeat)
}

let (t128, beat128) = clickTrack(bpm: 128, seconds: 9)
let e128 = t128.estimate()
check(e128.map { abs($0.period - 60.0 / 128) / (60.0 / 128) < 0.015 } ?? false,
      "a 128 BPM click is heard as 128 BPM (got \(e128.map { 60 / $0.period } ?? 0))")
check(e128.map { abs($0.lastBeat - beat128) < 0.025 } ?? false,
      "the last beat is placed within a sample or two of where it landed")
check((e128?.confidence ?? 0) > 0.3, "a steady click is heard with confidence")

let (t100, _) = clickTrack(bpm: 100, seconds: 9, offbeats: 0.45, seed: 7)
let e100 = t100.estimate()
check(e100.map { abs(60 / $0.period - 100) < 2 } ?? false,
      "kicks with hi-hats between them read as the kick's tempo, not double "
      + "(got \(e100.map { 60 / $0.period } ?? 0))")

let (t87, _) = clickTrack(bpm: 87, seconds: 9, seed: 3)
check(t87.estimate().map { abs(60 / $0.period - 87) < 1.5 } ?? false,
      "a slow 87 BPM track is not doubled")

var noiseOnly = TempoTracker(rate: onsetRate)
var noiseRng = Noise(state: 42)
for _ in 0..<Int(9 * onsetRate) { noiseOnly.push(noiseRng.next()) }
check((noiseOnly.estimate()?.confidence ?? 0) < 0.15,
      "noise with no pulse is not trusted (confidence \(noiseOnly.estimate()?.confidence ?? 0))")

var silent = TempoTracker(rate: onsetRate)
for _ in 0..<Int(9 * onsetRate) { silent.push(0) }
check(silent.estimate() == nil, "silence has no tempo")

var tooShort = TempoTracker(rate: onsetRate)
for i in 0..<Int(2 * onsetRate) { tooShort.push(i % 47 == 0 ? 1 : 0) }
check(tooShort.estimate() == nil, "two seconds is too little to judge a tempo")

// Following.
func beat(_ period: Double, at t: Double = 10, confidence: Double = 0.5) -> TempoTracker.Beat {
    TempoTracker.Beat(period: period, lastBeat: t, confidence: confidence)
}
var follower = BeatFollower()
follower.update(beat(0.5))
check(follower.period == nil, "one reading is not enough to trust a tempo")
follower.update(beat(0.505, at: 11))
check(follower.period.map { abs($0 - 0.505) < 1e-9 } ?? false,
      "a second agreeing reading locks the tempo")
follower.update(beat(0.25, at: 12))
check(follower.period.map { abs($0 - 0.505) < 0.01 } ?? false,
      "a half-period reading is the same pulse, not a new tempo")
for i in 0..<5 { follower.update(beat(0.505 * 1.5, at: 12.5 + Double(i))) }
check(follower.period.map { abs($0 - 0.505) < 0.01 } ?? false,
      "a run of triplet-feel (3:2) readings does not replace the tempo")
follower.update(beat(0.6, at: 13)); follower.update(beat(0.6, at: 14))
check(follower.period.map { $0 < 0.55 } ?? false,
      "two readings of a different tempo do not yet replace it")
follower.update(beat(0.6, at: 15))
check(follower.period.map { abs($0 - 0.6) < 1e-9 } ?? false,
      "a new tempo that holds for three readings takes over")
let anchorBefore = follower.anchor
follower.update(beat(0.6, at: 15.0 + 0.6 * 4 + 0.1))
check(abs(follower.anchor - (anchorBefore + 0.6 * 4 + 0.035)) < 1e-6,
      "a beat heard 0.1s late moves the grid 35% of the way, not all of it")
follower.update(beat(0.6, confidence: 0.05))
check(follower.period != nil, "one unsure reading does not drop the tempo")
for _ in 0..<3 { follower.update(nil) }
check(follower.period == nil, "four readings with no pulse drop the tempo")

// Beat alignment.
// Incoming beats at 0.25 + k·0.5 in its own time, playing at rate 1; read at
// media 10.1 at wall 100.0, so its next beat (10.25) lands at wall 100.15.
let lateBy = BeatAlign.error(incomingMedia: 10.1, readAt: 100, incomingPhase: 0.25,
                             incomingPeriod: 0.5, rate: 1, outgoingBeat: 99.1, outgoingPeriod: 0.5)
check(close(lateBy, 0.05, 1e-9), "an incoming beat 50ms after an outgoing one reads as 50ms late")
check(close(BeatAlign.shift(error: lateBy, rate: 1), 0.05, 1e-9),
      "a late incoming track is moved forward by the error")
let earlyBeat = BeatAlign.error(incomingMedia: 10.1, readAt: 100, incomingPhase: 0.25,
                                incomingPeriod: 0.5, rate: 1, outgoingBeat: 100.25, outgoingPeriod: 0.5)
check(close(earlyBeat, -0.1, 1e-9), "an incoming beat 100ms before an outgoing one reads as early")
// Rate 1.04: the next beat is at media 10.13 (0.25 + 19 × 0.52), 0.13 media
// seconds away — 0.125 wall seconds at 1.04×.
let stretched = BeatAlign.error(incomingMedia: 10.0, readAt: 50, incomingPhase: 0.25,
                                incomingPeriod: 0.52, rate: 1.04, outgoingBeat: 50.125, outgoingPeriod: 0.5)
check(abs(stretched) < 1e-3, "the playback rate is accounted for when finding the next beat")
check(close(BeatAlign.shift(error: 0.05, rate: 1.04, stall: 0.2), 0.26, 1e-9),
      "a seek that stalls jumps further by the stall, in the track's own time")
let halfTimeBeat = BeatAlign.error(incomingMedia: 3.9, readAt: 20, incomingPhase: 0,
                               incomingPeriod: 1.0, rate: 1, outgoingBeat: 20.1, outgoingPeriod: 0.5)
check(abs(halfTimeBeat) < 1e-9, "a half-time incoming track aligns to every other outgoing beat")

// MARK: - Spectrum meter

suite("Spectrum meter")

var steady = SpectrumMeter(bands: 2)
var steadyLevel: [Double] = []
for _ in 0..<600 { steadyLevel = steady.update([1e-3, 1e-5]) }
check(abs(steadyLevel[0] - 4.5 / 17) < 0.03,
      "a steady band settles about a quarter up (got \(steadyLevel[0]))")
let hit = steady.update([1e-3 * 16, 1e-5])        // +12 dB
var afterHit = hit
for _ in 0..<3 { afterHit = steady.update([1e-3 * 16, 1e-5]) }
check(afterHit[0] > 0.8, "a 12 dB hit jumps near the top within a few frames (got \(afterHit[0]))")
var fall = afterHit
for _ in 0..<20 { fall = steady.update([1e-3, 1e-5]) }
check(fall[0] < afterHit[0] - 0.3, "after a hit it falls back within about a fifth of a second")

var flicker = SpectrumMeter(bands: 1)
var rng2 = Noise(state: 9)
var total = 0.0
for i in 0..<2000 {
    let db = -30 + (rng2.next() - 0.5) * 8            // ±4 dB frame to frame
    let v = flicker.update([pow(10, db / 10)])[0]
    if i >= 1000 { total += v }
}
check(total / 1000 < 0.55, "frame-to-frame flicker does not pin the bars near the top (mean \(total / 1000))")

var floorMeter = SpectrumMeter(bands: 2)
var floorLevel: [Double] = []
for _ in 0..<300 { floorLevel = floorMeter.update([1e-2, 1e-2 * 1e-7]) }   // 70 dB down
check(floorLevel[1] == 0, "a band 70 dB under the loudest reads as nothing")

// MARK: - Result

print("\n\(checks - failures.count)/\(checks) passed")
if !failures.isEmpty {
    print("\n\u{001B}[31mFailures:\u{001B}[0m")
    for f in failures { print("  • \(f)") }
    exit(1)
}
