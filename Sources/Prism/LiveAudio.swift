#if canImport(AppKit)
import Foundation
import ScreenCaptureKit
import CoreGraphics
import AVFoundation
import Accelerate
import Observation
#if canImport(AutoMixCore)
import AutoMixCore
#endif

/// What the Mac is playing, reduced to a few numbers the light can react to.
///
/// Built on the same ScreenCaptureKit capture as `AudioProbe` — the only route
/// to the audio, since YouTube's stream is decoded inside WebKit and never
/// passes through Prism. Two costs come with it and are not hidden: macOS shows
/// its screen-recording indicator while capture runs, and it needs Screen &
/// System Audio Recording permission. So capture is **reference-counted**: it
/// runs only while something that uses it is on screen, and stops the moment
/// nothing is, taking the indicator with it.
@MainActor
@Observable
final class LiveAudio: NSObject, AudioBandsSource {

    /// Read every frame by the light, and deliberately *not* observed: if it
    /// were, every rim would invalidate its parent thirty times a second —
    /// including RootView, which is the whole app. The light samples it from
    /// inside its own timeline instead, so only the light redraws.
    @ObservationIgnored private(set) var bands = AudioBands.silent

    private(set) var running = false
    /// Why capture could not start, for Settings to show.
    private(set) var failure: String?

    @ObservationIgnored private var holders: Set<String> = []
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: CaptureOutput?
    @ObservationIgnored private var transition: Task<Void, Never>?

    /// Set after a failed start, so a missing permission is asked about once
    /// rather than retried in a tight loop. Cleared when every holder lets go,
    /// so opening the surface again tries again.
    @ObservationIgnored private var gaveUp = false

    /// Set when a start failed because the permission is missing. macOS only
    /// re-reads that permission when Prism relaunches (it offers "Quit &
    /// Reopen" after you grant it), so asking again this launch would only put
    /// the same prompt back up — every time the window came back into view.
    @ObservationIgnored private var permissionRefused = false

    static let permissionNote = "Live audio needs Screen & System Audio Recording "
        + "permission. Turn Prism on in System Settings → Privacy & Security, "
        + "then quit and reopen Prism."

    /// Hold capture open on behalf of `who`, or let go. Idempotent.
    func hold(_ who: String, _ wanted: Bool) { set(who, wanted) }

    /// Lets go on behalf of every holder whose name starts with `prefix`.
    func releaseAll(prefix: String) {
        let gone = holders.filter { $0.hasPrefix(prefix) }
        guard !gone.isEmpty else { return }
        holders.subtract(gone)
        if holders.isEmpty { gaveUp = false }
        reconcile()
    }

    func set(_ who: String, _ wanted: Bool) {
        if wanted { holders.insert(who) } else { holders.remove(who) }
        if holders.isEmpty { gaveUp = false }
        // A stream delivers buffers continuously, silence included, so one
        // that has gone quiet for seconds has stopped without saying so.
        if running, transition == nil, Date().timeIntervalSince(lastHeard) > 4 {
            streamDied("no audio for 4s")
        }
        reconcile()
    }

    /// When the capture last delivered audio.
    @ObservationIgnored private var lastHeard = Date()

    /// The stream is gone — macOS stopped it (display change, sleep, lock), or
    /// it went silent. It used to be left for dead with `running` still true,
    /// so nothing ever restarted it: measured, the tempo log simply stopped
    /// and the next song was never heard. Forget it and let reconcile start a
    /// fresh one if anyone still wants it.
    private func streamDied(_ why: String) {
        guard stream != nil || running else { return }
        log("capture stopped by the system (\(why)); restarting if still wanted")
        stream = nil
        output = nil
        running = false
        bands = .silent
        reconcile()
    }

    private func log(_ line: String) {
        guard ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1" else { return }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".prism-eval/tempo.log")
        let text = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) [capture] \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        }
    }

    /// Brings capture in line with whether anyone wants it.
    ///
    /// An in-flight start or stop is never cancelled — tearing an SCStream
    /// down half-started is how captures leak. It finishes, then this runs
    /// again and catches up with whatever changed meanwhile.
    @ObservationIgnored private var lastState = ""

    /// When a start last failed. Retried every 15 seconds while something
    /// still wants capture — a locked screen offers no display to capture, and
    /// capture used to stay off after unlocking until every holder let go.
    @ObservationIgnored private var gaveUpAt = Date.distantPast

    private func reconcile() {
        if gaveUp, !holders.isEmpty, Date().timeIntervalSince(gaveUpAt) > 15 { gaveUp = false }
        let state = "wanted by [\(holders.sorted().joined(separator: ", "))] running=\(running) "
            + "gaveUp=\(gaveUp) refused=\(permissionRefused) busy=\(transition != nil)"
        if state != lastState { lastState = state; log(state) }
        guard transition == nil else { return }
        let want = !holders.isEmpty
        guard want != running, !(want && gaveUp) else { return }
        transition = Task { [weak self] in
            guard let self else { return }
            if want { await self.start() } else { await self.stop() }
            if want && !self.running { self.gaveUp = true; self.gaveUpAt = Date() }
            self.transition = nil
            self.reconcile()
        }
    }

    private func start() async {
        guard stream == nil else { running = true; return }
        guard !permissionRefused else { failure = Self.permissionNote; return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                // What a locked screen looks like from here.
                failure = "No display to capture audio from"
                log("capture could not start: no display (is the screen locked?)")
                return
            }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // Audio is the point; the video side is as small and slow as allowed.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            let out = CaptureOutput { [weak self] b in
                Task { @MainActor in
                    self?.bands = b
                    self?.lastHeard = Date()
                }
            } stopped: { [weak self] error in
                Task { @MainActor in self?.streamDied(error.localizedDescription) }
            }
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                             configuration: config, delegate: out)
            try s.addStreamOutput(out, type: .audio,
                                  sampleHandlerQueue: DispatchQueue(label: "prism.liveaudio"))
            try await s.startCapture()
            stream = s
            output = out
            running = true
            lastHeard = Date()
            failure = nil
            log("capture started for \(holders.sorted().joined(separator: ", "))")
        } catch {
            // Most often: permission not granted. The light falls back to its
            // breathing rather than going dark.
            if !CGPreflightScreenCaptureAccess() {
                permissionRefused = true
                failure = Self.permissionNote
            } else {
                failure = "Live audio could not start: \(error.localizedDescription)"
            }
            log("capture failed to start: \(error.localizedDescription)")
            running = false
        }
    }

    private func stop() async {
        running = false
        bands = .silent
        guard let s = stream else { return }
        stream = nil
        output = nil
        log("capture stopped — nothing wants it")
        try? await s.stopCapture()
    }
}

/// Runs on the capture queue: mixes to mono, FFTs 1024-sample frames, and
/// posts smoothed bands at no more than 30 Hz.
private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let publish: (AudioBands) -> Void

    private let n = 1024
    private let log2n = vDSP_Length(10)
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var frame: [Float] = []

    private var smooth = AudioBands.silent
    /// Slowly decaying peak per band, so a quietly mastered track still moves
    /// the light as much as a loud one.
    private var peak: (Double, Double, Double) = (1e-6, 1e-6, 1e-6)
    private var bassAverage = 0.0
    private var lastOnset = Date.distantPast
    private var lastPost = Date.distantPast

    // Tempo. One onset-strength sample per hop: 48 kHz over a 512-sample hop.
    private var tracker = TempoTracker(rate: 48_000.0 / 512)
    private var follower = BeatFollower()
    private var hopsSinceEstimate = 0
    /// Roughly log-spaced groups of FFT bins, ~47 Hz to ~4.7 kHz: kick, snare
    /// and the body of most instruments, without the hiss above.
    private let fluxEdges = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18, 22, 27, 33, 40, 48, 58, 70, 84, 100]
    private var lastDB: [Double] = Array(repeating: 0, count: 19)
    /// Kick energy summed at each of the four beat positions, slowly
    /// forgotten, to tell which beat is the one.
    private var accents = [Double](repeating: 0, count: 4)
    private var lockedPeriod: Double?
    /// The beat being filled, and each finished beat's loudness.
    private var beatIndex: Int?
    private var beatSum = 0.0, beatCount = 0
    private var beats: [BeatEnergy] = []
    private var powerPeak = 1e-9
    private let tempoLog: URL? = ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1"
        ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".prism-eval/tempo.log")
        : nil

    private let stopped: (Error) -> Void

    init(publish: @escaping (AudioBands) -> Void, stopped: @escaping (Error) -> Void) {
        self.publish = publish
        self.stopped = stopped
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: n, isHalfWindow: false)
        super.init()
        frame.reserveCapacity(n * 2)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopped(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(buffer) else { return }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard listSize > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: listPtr,
            bufferListSize: listSize, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr
        else { return }

        // Mix every channel buffer down to mono.
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        let count = buffers.map { Int($0.mDataByteSize) / MemoryLayout<Float>.size }.min() ?? 0
        guard count > 0 else { return }
        var mono = [Float](repeating: 0, count: count)
        for b in buffers {
            guard let data = b.mData else { continue }
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                              count: count)
            vDSP.add(mono, samples, result: &mono)
        }
        vDSP.multiply(1 / Float(max(buffers.count, 1)), mono, result: &mono)

        frame.append(contentsOf: mono)
        while frame.count >= n {
            analyse(Array(frame.prefix(n)))
            frame.removeFirst(n / 2)          // 50% overlap
        }
    }

    private func analyse(_ samples: [Float]) {
        let windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &mags)
            }
        }

        // 48 kHz over 1024 points is ~47 Hz a bin.
        func band(_ lo: Int, _ hi: Int) -> Double {
            let slice = mags[max(lo, 1)..<min(hi, mags.count)]
            guard !slice.isEmpty else { return 0 }
            return Double(sqrt(vDSP.mean(Array(slice))))
        }
        let bass = band(1, 6)        // ~47–280 Hz
        let mid = band(6, 43)        // ~280 Hz–2 kHz
        let treble = band(43, 214)   // ~2–10 kHz

        // Auto-gain: normalise against a peak that decays over a few seconds.
        peak = (max(peak.0 * 0.9985, bass), max(peak.1 * 0.9985, mid), max(peak.2 * 0.9985, treble))
        let nb = min(bass / peak.0, 1), nm = min(mid / peak.1, 1), nt = min(treble / peak.2, 1)

        // Fast attack, slower release, so hits read as hits and tails settle.
        func follow(_ old: Double, _ new: Double) -> Double {
            old + (new - old) * (new > old ? 0.55 : 0.12)
        }
        smooth.bass = follow(smooth.bass, nb)
        smooth.mid = follow(smooth.mid, nm)
        smooth.treble = follow(smooth.treble, nt)
        smooth.level = follow(smooth.level, (nb * 0.5 + nm * 0.35 + nt * 0.15))

        // An onset is a sharp jump in the low end over its recent average.
        bassAverage += (nb - bassAverage) * 0.08
        let now = Date()
        if nb > 0.55, nb - bassAverage > 0.22, now.timeIntervalSince(lastOnset) > 0.18 {
            lastOnset = now
            smooth.onsetAt = now
        }

        followTempo(mags, now: now)
        smooth.spectrum = spectrum(mags)

        guard now.timeIntervalSince(lastPost) >= 1.0 / 30.0 else { return }
        lastPost = now
        publish(smooth)
    }

    // The equalizers' spectrum: 32 bands spaced by pitch, 40 Hz to 16 kHz.
    private static let spectrumEdges: [Int] = {
        var edges: [Int] = []
        for i in 0...32 {
            let f = 40 * pow(16_000.0 / 40, Double(i) / 32)
            var bin = max(Int((f / (48_000.0 / 1024)).rounded()), 1)
            if let last = edges.last, bin <= last { bin = last + 1 }
            edges.append(min(bin, 511))
        }
        return edges
    }()
    private var meter = SpectrumMeter(bands: 32)

    /// The equalizers' bars: power in each of the 32 bands, read by the meter.
    private func spectrum(_ mags: [Float]) -> [Double] {
        let edges = Self.spectrumEdges
        var power = [Double](repeating: 0, count: 32)
        for i in 0..<32 {
            let lo = edges[i], hi = max(edges[i + 1], lo + 1)
            var sum: Float = 0
            for k in lo..<min(hi, mags.count) { sum += mags[k] }
            power[i] = Double(sum) / Double(hi - lo)
        }
        return meter.update(power)
    }

    /// Feeds the tempo tracker one onset-strength sample, and once a second
    /// asks it where the beat is.
    ///
    /// Onset strength is spectral flux: how much louder each band got since the
    /// last frame, in dB, summed. Differences of dB ignore overall level, so a
    /// quietly mastered track finds its beat as readily as a loud one; the
    /// floor keeps near-silent bins from adding noise.
    private func followTempo(_ mags: [Float], now: Date) {
        var loudest = 0.0
        var flux = 0.0
        var kick = 0.0
        var body = 0.0
        for i in 0..<(fluxEdges.count - 1) {
            let lo = fluxEdges[i], hi = fluxEdges[i + 1]
            var sum: Float = 0
            for k in lo..<hi { sum += mags[k] }
            let power = Double(sum) / Double(hi - lo)
            loudest = max(loudest, power)
            let db = 10 * log10(max(power, powerPeak * 1e-5))
            flux += max(db - lastDB[i], 0)
            if i < 4 { kick += max(db - lastDB[i], 0) }       // ~47–230 Hz
            if i < 16 { body += power }                        // up to ~2.7 kHz
            lastDB[i] = db
        }
        powerPeak = max(powerPeak * 0.9995, loudest)
        tracker.push(flux)
        followBar(kick: kick, energy: body, now: now)

        hopsSinceEstimate += 1
        guard hopsSinceEstimate >= Int(tracker.rate) else { return }
        hopsSinceEstimate = 0
        let estimate = tracker.estimate()
        follower.update(estimate)

        if let period = follower.period {
            // The follower's anchor is on the tracker's sample clock; carry it
            // forward to the latest beat and pin that to the wall clock.
            let n = ((tracker.now - follower.anchor) / period).rounded(.down)
            let latest = follower.anchor + n * period
            smooth.tempo = period
            smooth.beatAt = now.addingTimeInterval(latest - tracker.now)
            // The latest beat that is the one, once the kick has said which.
            if accents.reduce(0, +) > 0 {
                let one = BarPhase.downbeat(accents: accents)
                var k = Int(n)
                while ((k % 4) + 4) % 4 != one { k -= 1 }
                smooth.downbeatAt = now.addingTimeInterval(follower.anchor + Double(k) * period - tracker.now)
            }
            smooth.recentBeats = beats
        } else {
            smooth.tempo = nil
            smooth.beatAt = nil
            smooth.downbeatAt = nil
        }
        logTempo(estimate)
    }

    /// Keeps the bar: which beat carries the kick, and each beat's loudness.
    /// Starts over when the tempo lock changes — a new song, most likely.
    private func followBar(kick: Double, energy: Double, now: Date) {
        guard let period = follower.period else { return }
        if let locked = lockedPeriod, abs(period / locked - 1) < 0.03 {} else {
            lockedPeriod = period
            accents = [0, 0, 0, 0]
            beats = []
            beatIndex = nil
        }
        let position = (tracker.now - follower.anchor) / period
        let k = Int(position.rounded())
        if abs(position - Double(k)) < 0.12 {
            for i in 0..<4 { accents[i] *= 0.999 }
            accents[((k % 4) + 4) % 4] += kick
        }
        if let current = beatIndex, current != k, beatCount > 0 {
            let at = now.addingTimeInterval(follower.anchor + Double(current) * period - tracker.now)
            beats.append(BeatEnergy(at: at, energy: beatSum / Double(beatCount)))
            if beats.count > 160 { beats.removeFirst(beats.count - 160) }
            beatSum = 0
            beatCount = 0
        }
        beatIndex = k
        beatSum += energy
        beatCount += 1
    }

    private func logTempo(_ e: TempoTracker.Beat?) {
        guard let tempoLog else { return }
        let heard = e.map { String(format: "heard %.1f BPM conf %.2f", 60 / $0.period, $0.confidence) }
            ?? "heard nothing"
        let locked = follower.period.map { String(format: "locked %.1f BPM", 60 / $0) } ?? "unlocked"
        let ticks = Array("▁▂▃▄▅▆▇█")
        let bars = String(smooth.spectrum.map { ticks[min(Int($0 * 8), 7)] })
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(heard) · \(locked) · \(bars)\n"
        if let h = try? FileHandle(forWritingTo: tempoLog) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: tempoLog, atomically: true, encoding: .utf8)
        }
    }
}
#endif
