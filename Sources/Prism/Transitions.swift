import Foundation
import WebKit
#if canImport(AppKit)
import AppKit
#endif
import Observation
// A module on macOS, compiled straight into the binary on iOS — see
// build-ios.sh. `canImport` covers both without forking the file.
#if canImport(AutoMixCore)
import AutoMixCore
#endif

/// Crossfade between tracks using a second, hidden YouTube player.
///
/// There is no way to fade *within* one web player: it plays one stream and
/// Prism cannot reach the decoded audio. So the overlap is real — a shadow
/// webview loads the next track and starts playing it while the main player is
/// still going, with the two volumes ramped against each other.
///
/// Two different curves are used, because the two halves of a transition are
/// mathematically different problems:
///
/// * **Song to song** is a fade between *uncorrelated* signals. Their powers
///   add, so equal-power (`cos`/`sin`, keeping `gainA² + gainB² = 1`) holds the
///   loudness flat. Two linear ramps would both sit at 0.5 halfway across and
///   sum to 0.707 of full power — an audible ~3 dB sag.
/// * **The handover** is a blend between two players carrying the *same* track
///   at the same position. Identical, aligned audio sums by *amplitude*, not
///   power, so equal-power is exactly wrong there: `cos + sin` peaks at √2, a
///   +3 dB bump right at the seam. Correlated signals want a linear pair.
///
/// Getting that backwards is what a listener hears as the join.
@MainActor
@Observable
final class Transitions {

    /// Whether this platform can perform a crossfade at all.
    ///
    /// **iOS cannot, and the reason is not a missing API but a lie.** WebKit on
    /// iOS ignores `HTMLMediaElement.volume` once media is attached: the setter
    /// accepts the value, reads it back once, and the element then returns to 1
    /// with no `volumechange` event ever firing. Measured with a track loaded
    /// (`readyState 4`, duration 232.8s), three consecutive trials:
    ///
    ///     v.volume = 0.2   ->  reads 0.2, then 1
    ///     volumechange events: 0
    ///     p.setVolume(20)  ->  getVolume() says 20, element volume is 1
    ///
    /// YouTube's own wrapper reports a gain it did not apply, which is what
    /// makes this worth spelling out: every ramp *looks* like it worked. An
    /// earlier measurement in this project found volume writable and was wrong
    /// — it was taken on an idle page with nothing loaded, where the clamp does
    /// not yet apply. Measure with media attached or do not measure at all.
    ///
    /// A fade driven by an inert gain is not a quiet failure. Both tracks would
    /// play at full volume for the whole overlap and then cut, which is
    /// audibly worse than no crossfade. So it is off here, and says why, rather
    /// than running and sounding broken. `mute` does work, but mute is binary
    /// and a blend needs a ramp.
    static var isSupported: Bool {
        #if canImport(AppKit)
        return true
        #else
        return false
        #endif
    }

    /// Why crossfade is unavailable, for the UI to show instead of a slider.
    static var unsupportedReason: String? {
        isSupported ? nil
            : "iOS ignores volume changes from a web player, so a crossfade "
            + "would play both tracks at full volume instead of blending them."
    }

    /// Shortest blend Prism will perform. Anything under this is not a mix.
    static let minimumBlend: Double = AutoMix.minimumDuration

    /// 0 turns crossfade off entirely; the shadow player is then never loaded.
    /// Any other value is held at or above the minimum.
    var seconds: Double = 0 {
        didSet {
            if seconds > 0, seconds < Self.minimumBlend {
                seconds = Self.minimumBlend
                return                       // the re-entrant set finishes the job
            }
            if seconds <= 0 { cancelFade("crossfade turned off") }
            UserDefaults.standard.set(seconds, forKey: "prism.crossfade")
        }
    }

    private(set) var fading = false
    /// Why the last transition was not a crossfade, for the UI to surface.
    private(set) var lastProblem: String?

    /// Tracks shorter than this never crossfade — the fade would eat most of
    /// the song, and arming overlaps firing. A six-second floor on the blend
    /// needs more headroom than the old three-second one did: the track has to
    /// hold the blend, the arming window before it, and still be a song.
    private let minimumTrackLength: Double = 45

    /// When on, the crossfade slider becomes a *preference* and AutoMix picks
    /// the real length from the two tempos. Off, the slider is exact.
    var autoMix: Bool = UserDefaults.standard.bool(forKey: "prism.automix") {
        didSet { UserDefaults.standard.set(autoMix, forKey: "prism.automix") }
    }

    /// Whether the *outgoing* track bends too, or only the incoming one.
    ///
    /// On, the two tracks meet in the middle and the old song is heard leaning
    /// into the new one. That lean is not free: each of its two or three rate
    /// changes freezes the outgoing audio for around half a second, placed late
    /// in the blend where that track is 10 dB down and the incoming one should
    /// be covering it. Off, the incoming track absorbs the whole tempo
    /// difference silently — the beats still line up, there is just no audible
    /// lead-in and not a single dropout. The escape hatch exists because
    /// whether the masking works is a question about ears, not numbers.
    var bendOutgoing: Bool = UserDefaults.standard.object(forKey: "prism.bend") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bendOutgoing, forKey: "prism.bend") }
    }

    /// The last plan, so the UI can say what it decided and why.
    private(set) var lastPlan: TransitionPlan?
    /// Plan for the armed track, worked out before the fade fires so its
    /// duration can decide *when* to fire.
    private var pendingPlan: TransitionPlan?

    let analysis = TrackAnalysisService()

    /// What this pipeline can actually execute.
    ///
    /// Time-stretch used to be declared unavailable here, and that was wrong.
    /// The media element accepts any `playbackRate` and supports
    /// `preservesPitch`, so the tempo can be moved without changing the key —
    /// measured exact on the real player: 1.06 set, 1.060 played. What it
    /// *cannot* do is move the tempo for free; every change costs about half a
    /// second of frozen audio, which is why the capability carries a price and
    /// the planner spends it carefully. Filtering is still genuinely absent.
    private let capabilities = MixCapabilities.webPlayer

    private unowned let engine: Engine
    private var shadow: WKWebView?
    private var shadowReady = false

    private var armedFor: String?      // videoId the shadow is holding
    private var fadingFrom: String?    // videoId we started the fade on
    private var restoreVolume: Double? // what the main player was at before
    /// Head start the plan gave the incoming track, so a blind alignment knows
    /// the shadow did not begin at zero.
    private var incomingOffset: Double = 0
    /// True only during the swap, when the player legitimately stops for a
    /// moment. Outside it, a stopped player means the user pressed pause.
    private var handingOver = false
    private var fadeTask: Task<Void, Never>?
    private var armTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    // MARK: Logging

    /// stdout is a black hole for a bundled app launched with `open`, so the
    /// fade trace lands in a file. Only written when the debug console is
    /// enabled, and the handle is opened once rather than per line — this used
    /// to open and close a FileHandle twenty times a second on the main actor.
    private static let logURL: URL? = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".prism-eval")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let url = dir.appendingPathComponent("fade.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }()

    // @Observable rejects `lazy`, and this is not state anything should
    // observe, so it is opened once in init and ignored by the macro.
    @ObservationIgnored private var logHandle: FileHandle?

    private func trace(_ line: String) {
        guard let logHandle else { return }
        logHandle.write(Data("\(Date().timeIntervalSince1970.rounded()) \(line)\n".utf8))
    }

    init(engine: Engine) {
        self.engine = engine
        if let url = Self.logURL, let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            logHandle = h
        }
        seconds = UserDefaults.standard.double(forKey: "prism.crossfade")
    }

    // MARK: Driving

    /// Called on every snapshot. Preloads, starts the fade, and bails out of one
    /// the moment the state stops matching what the fade assumes.
    func tick(_ snap: EngineSnapshot) {
        // Nothing here can work without a working gain control. Bail before
        // arming a shadow player whose fade would be inaudible as a fade.
        guard Self.isSupported else { return }
        if fading {
            // The user skipped, or something else moved the player out from
            // under us. Left alone the ramp would keep pulling the main
            // player's volume down on a track that is not the one being faded,
            // and it would never reach the handover that puts it back.
            let id = snap.track?.videoId
            if id != fadingFrom && id != armedFor {
                cancelFade("track changed under the fade")
            } else if !handingOver && !snap.playback.isPlaying {
                cancelFade("paused mid-fade")
            }
            return
        }

        guard seconds > 0 else { return }
        guard let track = snap.track, snap.duration > 0, snap.playback.isPlaying else { return }
        guard snap.duration >= minimumTrackLength else { return }
        guard let next = nextTrack(in: snap) else { return }

        let remaining = snap.duration - snap.currentTime

        // Look both tracks up early, off the critical path, so the planner has
        // something to work with by the time the fade starts. Two network round
        // trips per track against Deezer, so this wants a wide margin — an
        // analysis that lands after the plan is made is worth nothing, and a
        // missing tempo is the single most common reason a mix degrades to a
        // plain fade.
        if autoMix, remaining < seconds + 60 {
            analysis.prefetch(videoId: track.videoId, title: track.title,
                              artist: track.artist, duration: snap.duration)
            analysis.prefetch(videoId: next.videoId, title: next.title,
                              artist: next.artist, duration: 0)
        }

        // Load the next track well before it is needed; a cold player takes a
        // couple of seconds to be ready to make sound, and a blend that is now
        // at least six seconds long has to be fully armed before it starts.
        if remaining < seconds + 18, armedFor != next.videoId {
            trace("[FADE_MATH] arming \(next.title) — \(String(format: "%.1f", remaining))s left")
            arm(next.videoId)
        }

        // Plan before firing, because the plan decides *when* to fire. A fade
        // that fires at the slider's length but only runs for the planned
        // length ends early and takes the last seconds of the outgoing track
        // with it — an 84.9 BPM pair plans 2.83s, so a 6s trigger cut three
        // seconds off the end of every song.
        if armedFor == next.videoId, pendingPlan == nil {
            pendingPlan = makePlan(outgoing: track.videoId, remaining: remaining)
        }
        let fireAt = pendingPlan?.duration ?? seconds

        if remaining <= fireAt, armedFor == next.videoId, fadingFrom != track.videoId {
            start(from: track.videoId, remaining: remaining, volume: snap.volume)
        }
    }

    private func nextTrack(in snap: EngineSnapshot) -> QueueEntry? {
        let i = snap.queueIndex + 1
        guard i > 0, i < snap.queue.count else { return nil }
        return snap.queue[i]
    }

    // MARK: Shadow player

    private func makeShadow() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Same data store as the main engine, so the shadow is signed in too and
        // gets the same Premium stream rather than an ad.
        config.websiteDataStore = .default()
        WKWebView.prismConfiguration(config)

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 270), configuration: config)
        view.customUserAgent = engine.webView.customUserAgent
        view.prismMakeTransparent()
        return view
    }

    /// The shadow has to live in the window, or it never makes a sound.
    ///
    /// This is the same trap the main engine has: WebKit suspends media in a
    /// webview that is detached or zero-sized. The shadow spent an entire fade
    /// reporting player state -1 while its volume ramped dutifully from 0 to 97
    /// — the ramp was real, the audio was not. Mounted behind everything at
    /// near-zero alpha it is invisible and still allowed to play.
    /// - Note: iOS is stricter about this than macOS, not looser, so the same
    ///   rule holds and for the same reason: real size, real place in the
    ///   hierarchy, behind everything, near-zero alpha. `insertSubview(_:at: 0)`
    ///   is the counterpart of `positioned: .below`.
    private func mount(_ view: WKWebView) {
        guard view.superview == nil else { return }
        view.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
        #if canImport(AppKit)
        guard let host = engine.webView.window?.contentView else { return }
        view.alphaValue = 0.02
        host.addSubview(view, positioned: .below, relativeTo: nil)
        #else
        guard let host = engine.webView.window else { return }
        view.alpha = 0.02
        view.isUserInteractionEnabled = false
        host.insertSubview(view, at: 0)
        #endif
    }

    private func arm(_ videoId: String) {
        armTask?.cancel()
        pendingPlan = nil
        armedFor = videoId
        shadowReady = false

        let view = shadow ?? makeShadow()
        shadow = view
        mount(view)

        // music.youtube.com, not youtube.com/embed. The embed player reported
        // "no player" and never made a sound — its API is not there on the
        // timeline we need, and music tracks are frequently blocked from
        // embedding anyway. The real site is heavier but it is signed in, gets
        // the Premium stream, and exposes exactly the API the main engine uses.
        view.load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(videoId)")!))

        armTask = Task { [weak self] in
            guard let self else { return }

            // Two goes at it. A shadow that never becomes ready is the single
            // most common reason a mix silently degrades to a plain track
            // change, and much of the time the page simply lost the race —
            // a stalled load, a consent frame, a slow cold start. Reloading
            // once costs a few seconds of the arming window, which is why that
            // window was widened, and it converts a fair share of the failures
            // into working mixes rather than giving up on the first try.
            for pass in 0..<2 {
                if pass > 0 {
                    trace("[FADE_MATH] shadow stalled — reloading once")
                    guard !Task.isCancelled, armedFor == videoId, let view = shadow else { return }
                    view.load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(videoId)")!))
                }

                // Poll for the player rather than sleeping a fixed interval and
                // hoping. `shadowReady` is only set once the page has actually
                // buffered — the old code set it unconditionally, which is why
                // a silent shadow went unnoticed.
                for attempt in 0..<18 {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled, armedFor == videoId else { return }
                    let state = await js("""
                    (function(){
                      var p = document.querySelector('#movie_player');
                      if (!p || !p.getPlayerState) return 'none';
                      try {
                        p.mute(); p.setVolume(0); p.playVideo();
                        return String(p.getPlayerState()) + ':' + String(p.getCurrentTime());
                      } catch (e) { return 'err ' + e.message; }
                    })()
                    """) ?? "none"

                    // 1 = playing, 3 = buffering. Either means audio is flowing
                    // and the fade-in will be heard. 5 = cued but stalled,
                    // 2 = paused, 0/-1 = never started; an unplayable or
                    // region-blocked track sits in those forever, which the
                    // attempt cap catches.
                    if state.hasPrefix("1") || state.hasPrefix("3") {
                        // Park it paused at the start. The rate for the mix is
                        // set later, while it is still paused here — which is
                        // the only moment a rate change costs nothing.
                        fire("(function(){var p=document.querySelector('#movie_player'); if(p){p.pauseVideo(); p.seekTo(0,true);}})()")
                        shadowReady = true
                        trace("[FADE_MATH] shadow ready after \(attempt + 1) polls on pass \(pass + 1) (\(state))")
                        return
                    }
                }
            }
            trace("[FADE_MATH] shadow never became ready after two passes — playing through")
            lastProblem = "That track would not preload, so the change was a normal one."
            armedFor = nil
            releaseShadow()
        }
    }

    // MARK: The fade

    private func start(from videoId: String, remaining: Double, volume: Double) {
        guard shadowReady, shadow != nil else { return }
        fading = true
        fadingFrom = videoId

        let plan = pendingPlan ?? makePlan(outgoing: videoId, remaining: remaining)
        lastPlan = plan
        for note in plan.notes { trace("[AUTOMIX] \(note)") }

        // Never longer than what is actually left of the track.
        let fade = max(min(plan.duration, remaining), 0.5)
        let target = max(volume, 1)
        restoreVolume = target

        // Beat-match the incoming track *now*, while it is still paused.
        //
        // This is the one rate change that is completely free. Arming left the
        // shadow paused at 0, and a rate set on a paused element survives both
        // the seek and the play that follow — measured: set 1.04 while paused,
        // still 1.04 after seeking and playing, and effective 1.040 once it
        // ran. Spend it here and the whole overlap has its beats lined up
        // without a single dropout.
        if let rate = plan.tempoRamp?.incomingRate, abs(rate - 1) > 1e-4 {
            fire("(function(){var v=document.querySelector('video'); if(v){v.preservesPitch=true; v.playbackRate=\(rate);}})()")
            trace(String(format: "[FADE_MATH] incoming beat-matched at ×%.4f while paused", rate))
        }

        // Start the incoming track past its intro when the plan asks for it.
        incomingOffset = plan.startOffsetForIncoming
        if plan.startOffsetForIncoming > 0 {
            fire("(function(){var p=document.querySelector('#movie_player'); if(p) p.seekTo(\(plan.startOffsetForIncoming), true);})()")
        }

        armWatchdog(for: fade)
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            guard let self else { return }
            await runFade(seconds: fade, target: target, ramp: plan.tempoRamp)
        }
    }

    /// Asks AutoMix for a transition, or falls back to the slider.
    ///
    /// Everything the planner cannot justify degrades to the plain timed fade:
    /// no tempo for either track, low confidence, or a tempo pair too far apart
    /// to reconcile. The slider value is what it falls back *to*, so turning
    /// AutoMix on never makes a transition worse than it was.
    private func makePlan(outgoing: String, remaining: Double) -> TransitionPlan {
        guard autoMix else {
            return .fallback(seconds: seconds, reason: "AutoMix off; using the set length")
        }
        guard let a = analysis.cached(outgoing),
              let nextId = armedFor, let b = analysis.cached(nextId) else {
            return .fallback(seconds: seconds, reason: "no analysis yet; using the set length")
        }
        return AutoMix.plan(from: a, to: b, preferred: seconds,
                            capabilities: capabilities,
                            maxDuration: min(16, max(remaining, 1)),
                            // 0 hands the whole tempo difference to the
                            // incoming track, which absorbs it silently.
                            bendShare: bendOutgoing ? 0.5 : 0)
    }

    private func runFade(seconds fade: Double, target: Double, ramp: TempoRamp?) async {
        fire("(function(){var p=document.querySelector('#movie_player'); if(p){p.unMute(); p.setVolume(0); p.playVideo();}})()")

        // The outgoing bend, fired as the blend passes each step's position.
        // Consumed in order rather than recomputed, so a slow bridge or a
        // stalled tick can never apply the same freeze twice.
        var pendingSteps = ramp?.outgoingSteps ?? []

        // Deadline-driven, not step-driven. Each step also awaits a JS round
        // trip, so counting steps made a 5s fade take 6s and the outgoing track
        // ended before the ramp finished. Reading the clock keeps the fade the
        // length it claims to be however slow the bridge is.
        let began = Date()
        var lastTraced = -1.0
        while true {
            if Task.isCancelled { return }
            let elapsed = Date().timeIntervalSince(began)
            let t = min(elapsed / fade, 1)

            // Equal-power: the two songs are uncorrelated, so their *powers*
            // add and this keeps the sum flat.
            let out = cos(t * .pi / 2)
            let into = sin(t * .pi / 2)

            engine.setVolume(target * out)
            fire("(function(){var p=document.querySelector('#movie_player'); if(p) p.setVolume(\(target * into));})()")

            // Bend the outgoing track towards the meeting tempo. Each of these
            // freezes its audio for around half a second, which is why they
            // only ever land past 0.60 — by here the outgoing track is below
            // −5 dB and the incoming one is roughly 3 dB louder and covering
            // it. This is the part meant to be heard as the old song leaning
            // into the new one.
            if let step = pendingSteps.first, t >= step.at {
                pendingSteps.removeFirst()
                engine.setPlaybackRate(step.rate)
                trace(String(format: "[FADE_MATH] bend at t %.2f → ×%.4f (out gain %.3f)",
                             t, step.rate, out))
            }

            if elapsed - lastTraced > 0.5 {
                lastTraced = elapsed
                let shadowNow = await shadowClock()
                trace(String(format: "[FADE_MATH] t %.2f  out %.3f  in %.3f  shadow @ %.2f",
                             t, out, into, shadowNow))
            }
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(40))
        }

        if Task.isCancelled { return }
        await handover(target: target, elapsedFade: Date().timeIntervalSince(began),
                       shadowRate: ramp?.incomingRate ?? 1)
    }

    /// The seam.
    ///
    /// The main player is silent here, so it can be moved onto the track the
    /// shadow is already playing without anyone hearing it — but only if it
    /// lands on the same *position*. YouTube's seek is not sample accurate, so
    /// the alignment is measured and corrected rather than assumed, and the
    /// blend that follows is linear because both players now carry identical
    /// audio (see the note on the type).
    ///
    /// - Parameter shadowRate: tempo the incoming track has been playing at.
    ///   The shadow's clock advances at this rate, so every prediction about
    ///   where it will be has to be scaled by it, and the main player — which
    ///   comes back from a track load at 1.0 — inherits the track at its own
    ///   natural tempo. That step back to native is the price of not spending
    ///   another half-second freeze on audible music, and at the few percent
    ///   the planner allows it is far cheaper than the dropout would be.
    private func handover(target: Double, elapsedFade: TimeInterval,
                          shadowRate: Double) async {
        let expected = armedFor
        handingOver = true

        // Mute, not just volume 0. Loading a track resets the player's volume
        // back to whatever YouTube has stored, so a `setVolume(0)` issued
        // before the skip does not survive it — the incoming track came up at
        // full volume on 0:00 and audibly played its opening again while the
        // shadow was already seconds in. That is the "it restarts from the
        // beginning" bug. Mute survives the load, and the volume is re-asserted
        // on every poll below until the blend deliberately lifts it.
        engine.mute()
        engine.setVolume(0)
        // Undo the bend before the swap. A track load resets the rate to 1 by
        // itself, but doing it here explicitly means the one case where it does
        // not — the track having already advanced on its own — cannot leave the
        // next song running several percent fast for its whole length. Free
        // either way: the player is muted.
        engine.setPlaybackRate(1)

        // Only skip if YouTube has not already done it for us. The outgoing
        // track reaches its natural end at exactly the moment the fade finishes,
        // so it often auto-advances on its own — and calling next() on top of
        // that jumped a whole track, which is why a fade from "Good Morning"
        // landed on "Champion" instead of "Stronger".
        if engine.snapshot.track?.videoId != expected {
            engine.next()
        } else {
            trace("[FADE_MATH] already advanced; not skipping")
        }

        var ready = false
        for _ in 0..<40 {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(100))
            // Re-assert on every pass: the reset lands whenever the new track
            // finishes loading, which is somewhere inside this loop.
            engine.mute()
            engine.setVolume(0)
            engine.setPlaybackRate(1)
            let snap = engine.snapshot
            if snap.track?.videoId == expected, snap.duration > 0, snap.playback.isPlaying {
                ready = true
                break
            }
        }

        guard ready else {
            trace("[FADE_MATH] handover timed out — restoring volume")
            lastProblem = "The next track was slow to start, so that change was a normal one."
            finish(restoreTo: target)
            return
        }

        // Align. Read both clocks, seek the main player to the shadow's
        // position plus the round-trip it will take to get there, and check.
        // Without this the join lands tens to hundreds of milliseconds out and
        // you hear the track jump.
        // Correct once, check, and stop. Seeking is not free — YouTube
        // re-buffers afterwards and the clock stalls while it does, so the
        // player lands slightly *behind* wherever it was aimed. Chasing that
        // makes things worse: a run that reached 44ms drift then took a third
        // correction and ended at 132ms. Accept anything inside the band, and
        // never trade a good result for a worse one.
        var drift = Double.infinity
        var best = Double.infinity
        var lastShadow = 0.0

        // How long a seek really takes to land and resume, learned as we go.
        //
        // A fixed guess cannot work here. Seeking costs a round trip *plus* a
        // re-buffer whose length depends on the network and the moment, and
        // aiming with a constant guess converges to a constant error rather
        // than to zero: measured +0.159 then +0.132 on consecutive attempts,
        // both of them the same ~0.15s of unaccounted latency, never improving.
        // Feeding each measured drift back into the estimate makes the next
        // seek aim at where the shadow *will* be instead of where it was.
        var latency = 0.2
        for attempt in 0..<4 {
            if Task.isCancelled { return }
            engine.setVolume(0)
            let before = Date()
            let shadowTime = await shadowClock()
            let mainTime = await engine.liveTime()
            guard shadowTime > 0, mainTime >= 0 else {
                trace("[FADE_MATH] could not read a clock; falling back to the fade length")
                break
            }
            lastShadow = shadowTime

            drift = shadowTime - mainTime
            trace(String(format: "[FADE_MATH] align %d shadow %.3f main %.3f drift %+.3f",
                         attempt, shadowTime, mainTime, drift))

            // Under ~60ms two copies of the same audio blend without anything
            // audible; past that you hear the track step.
            if abs(drift) < 0.06 { break }
            if abs(drift) > best {
                trace("[FADE_MATH] correction diverging — keeping previous alignment")
                break
            }
            best = abs(drift)

            // Everything measured so far said the main player lands `drift`
            // behind where it was aimed, so aim that much further ahead.
            if attempt > 0 { latency += drift }

            // Lead by the measurement round trip plus the learned latency,
            // scaled by the shadow's tempo — a beat-matched shadow covers more
            // or less of its own timeline per wall-clock second than the main
            // player will, and aiming at an unscaled lead lands short.
            let lead = (Date().timeIntervalSince(before) + latency) * shadowRate
            engine.seek(to: shadowTime + lead)
            // Long enough for the seek to land and playback to resume before
            // the next reading, or the measurement is of a stalled clock.
            try? await Task.sleep(for: .milliseconds(350))
        }

        // Never blend into a player that is not where it should be.
        //
        // The loop above has three exits that can leave the main player
        // unaligned: a clock that would not read, a correction that diverged,
        // and simply running out of attempts. Blending regardless is what makes
        // the incoming track restart from its opening after the mix-in — the
        // listener hears it fade in, then hears it begin again. The rescue
        // below aims at the fade length when there is no shadow clock to trust,
        // because that is where the incoming track must be by definition.
        //
        // The blind estimate has to account for both the head start the plan
        // gave the incoming track and the tempo it has been running at: after
        // `elapsedFade` wall seconds at `shadowRate`, it has covered
        // `elapsedFade × shadowRate` of its own timeline.
        let expectedPosition = lastShadow > 0
            ? lastShadow
            : incomingOffset + elapsedFade * shadowRate
        var mainNow = await engine.liveTime()
        if mainNow >= 0, expectedPosition > 1, abs(expectedPosition - mainNow) > 0.5 {
            trace(String(format: "[FADE_MATH] rescue: main at %.2f, should be near %.2f",
                         mainNow, expectedPosition))
            engine.seek(to: expectedPosition + 0.25)
            try? await Task.sleep(for: .milliseconds(400))
            mainNow = await engine.liveTime()
            drift = expectedPosition - mainNow
            trace(String(format: "[FADE_MATH] rescue landed at %.2f", mainNow))
        }

        // Linear, not equal-power. Both players are now carrying the same audio
        // at the same place, so the sum is coherent: amplitudes add, and a
        // cos/sin pair would peak at √2 — a +3 dB lift exactly at the join.
        // Only now does the main player become audible, on the position the
        // shadow reached rather than on the track's opening.
        engine.unmute()
        let blendSteps = 8
        for step in 1...blendSteps {
            if Task.isCancelled { return }
            let a = Double(step) / Double(blendSteps)
            engine.setVolume(target * a)
            fire("(function(){var p=document.querySelector('#movie_player'); if(p) p.setVolume(\(target * (1 - a)));})()")
            try? await Task.sleep(for: .milliseconds(18))
        }

        trace(String(format: "[FADE_MATH] handover complete, residual drift %+.3f", drift))
        finish(restoreTo: target)
    }

    // MARK: Teardown

    /// Every exit from a fade goes through here. Leaving early without it was
    /// the worst bug in this file: a cancelled ramp left the main player's
    /// volume wherever it had got to — often near zero — with `fading` stuck
    /// true, so the app went quiet and crossfade never ran again.
    private func finish(restoreTo volume: Double?) {
        engine.unmute()
        if let volume { engine.setVolume(volume) }
        // Always hand the player back at its own tempo. A fade abandoned
        // part-way through the bend — the user skips, pauses, or the shadow
        // dies — would otherwise leave the song running a few percent fast
        // with nothing left to put it right, and every later track would
        // inherit it. This is the counterpart to restoring the volume, and it
        // is just as easy to forget.
        engine.setPlaybackRate(1)
        // Only nudge playback back if the swap left it stopped. Resuming after
        // the *user* paused mid-fade would be fighting them.
        if handingOver, !engine.snapshot.playback.isPlaying { engine.play() }
        watchdog?.cancel()
        watchdog = nil
        handingOver = false
        fading = false
        armedFor = nil
        fadingFrom = nil
        restoreVolume = nil
        incomingOffset = 0
        pendingPlan = nil
        shadowReady = false
        releaseShadow()
    }

    func cancelFade(_ reason: String) {
        armTask?.cancel(); armTask = nil
        fadeTask?.cancel(); fadeTask = nil
        watchdog?.cancel(); watchdog = nil
        guard fading || shadow != nil else { return }
        trace("[FADE_MATH] cancelled: \(reason)")
        finish(restoreTo: fading ? restoreVolume : nil)
    }

    /// Last line of defence.
    ///
    /// Every stage of a fade has its own timeout, but they are all inside the
    /// same task — if that task is somehow stuck awaiting a bridge call that
    /// never returns, none of them fire, and the player is left muted, bent and
    /// silent with `fading` stuck true, which also blocks every future fade.
    /// This runs outside that task and cannot be starved by it.
    private func armWatchdog(for fade: Double) {
        watchdog?.cancel()
        let limit = fade + 25
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled, fading else { return }
            trace(String(format: "[FADE_MATH] watchdog fired after %.0fs — recovering", limit))
            lastProblem = "A transition stalled, so playback was restored."
            fadeTask?.cancel(); fadeTask = nil
            finish(restoreTo: restoreVolume)
        }
    }

    /// Stops the media, takes the view out of the hierarchy, and drops it.
    ///
    /// `shadow = nil` alone is not enough — the superview holds its own
    /// reference, so the webview stayed mounted and alive after every fade.
    private func releaseShadow() {
        guard let view = shadow else { return }
        view.evaluateJavaScript(
            "(function(){var p=document.querySelector('#movie_player'); if(p){p.setVolume(0); p.pauseVideo(); p.stopVideo && p.stopVideo();}})()")
        view.loadHTMLString("", baseURL: nil)
        view.removeFromSuperview()
        shadow = nil
    }

    // MARK: Shadow JS

    /// Dispatch without waiting. Used wherever the reply is not needed, so the
    /// volume ramp is not paced by the bridge's round trip.
    private func fire(_ source: String) {
        shadow?.evaluateJavaScript(source)
    }

    @discardableResult
    private func js(_ source: String) async -> String? {
        guard let shadow else { return nil }
        return await withCheckedContinuation { cont in
            shadow.evaluateJavaScript(source) { value, _ in
                cont.resume(returning: value as? String)
            }
        }
    }

    private func shadowClock() async -> Double {
        let raw = await js("(function(){var p=document.querySelector('#movie_player');return p?String(p.getCurrentTime()):'';})()")
        return Double(raw ?? "") ?? -1
    }
}
