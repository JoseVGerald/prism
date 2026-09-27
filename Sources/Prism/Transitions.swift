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
    /// How a transition is performed here.
    ///
    /// The two are the same machinery — plan, shadow player, tempo ramp,
    /// handover — differing only in what happens at the seam.
    enum Mode {
        /// Overlap the two tracks and ramp their gains against each other.
        case blend
        /// No overlap: bend the outgoing tempo to meet the incoming one, then
        /// switch in a single step on the beat.
        case cut
    }

    /// macOS can blend because its web player honours `volume`. iOS cannot —
    /// see `modeNote` — so it cuts instead of pretending.
    static var mode: Mode {
        #if canImport(AppKit)
        return .blend
        #else
        return .cut
        #endif
    }

    /// Whether a managed transition of any kind is possible.
    static var isSupported: Bool { true }

    /// What this platform actually does between tracks, in one sentence for
    /// the settings panel. Not an apology on iOS: a cut on the beat, with the
    /// outgoing track's tempo led into it, is a real transition.
    static var modeNote: String {
        switch mode {
        case .blend:
            return "Tracks overlap and fade across each other."
        case .cut:
            return "The outgoing track's tempo is bent to meet the next one, "
                 + "then the two are switched in a single step on the beat. "
                 + "iOS will not let Prism fade a YouTube stream, so this is a "
                 + "cut rather than a blend — the beats still line up."
        }
    }

    /// Why crossfade is unavailable, for the UI to show instead of a slider.
    /// Kept for callers that want to explain a *missing* feature. Nothing is
    /// missing now — iOS cuts instead of blending — so this is always nil and
    /// `modeNote` is what the UI should show.
    ///
    /// The measurement behind the cut, kept because it is the reason:
    /// `video.volume = 0.3` reads back 0.3 and is reverted to 1 within a
    /// second; `setVolume(30)` reports 30 forever while the element stays at 1.
    /// Web Audio is not a way round it either — an oscillator through a
    /// `GainNode` measures peak 0.25 at gain 0.25 and a plain `<audio>` element
    /// measures RMS 0.259 at gain 1.0 and 0.072 at gain 0.2, but YouTube's
    /// element through the same graph, playing, measures exactly zero. Its
    /// media is MSE-backed and iOS decodes that in the platform pipeline, which
    /// it will not route into Web Audio.
    static var unsupportedReason: String? { nil }

    /// Shortest blend Prism will perform. Anything under this is not a mix.
    static let minimumBlend: Double = AutoMix.minimumDuration

    /// 0 turns crossfade off entirely; the shadow player is then never loaded.
    /// Any other value is held at or above the minimum.
    /// Longest blend the slider offers, and the most AutoMix will plan.
    static let maximumBlend: Double = 30

    /// How one song hands to the next.
    enum Style: String, CaseIterable {
        /// A long crossfade: both songs meet in the middle.
        case blend
        /// A DJ switch: the new song sneaks in underneath for a few bars and
        /// everything swaps on the one, the new song entering at its drop.
        case switchCut = "switch"
    }

    var style: Style = Style(rawValue: UserDefaults.standard.string(forKey: "prism.mixStyle") ?? "")
        ?? .switchCut {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "prism.mixStyle") }
    }

    /// The moment of the switch, and the incoming track's position that has
    /// to land on it (its drop, or a bar line), while a switch is under way.
    private var switchAt: Date?
    private var switchEntry: Double?
    private var scheduledStart: Task<Void, Never>?

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
    /// When the running blend began and how long it lasts, nil otherwise.
    /// Published once per fade rather than as a progress value: locked mode
    /// works the position out from the clock every frame, so its picture moves
    /// smoothly with the audio, and no view is invalidated by the 40ms loop.
    /// Past its length it reads as 1 — held through the handover.
    private(set) var fadeClock: (began: Date, length: Double, from: String?)?
    /// Why the last transition was not a crossfade, for the UI to surface.
    private(set) var lastProblem: String?

    /// Tracks shorter than this never crossfade — the fade would eat most of
    /// the song, and arming overlaps firing. A six-second floor on the blend
    /// needs more headroom than the old three-second one did: the track has to
    /// hold the blend, the arming window before it, and still be a song.
    ///
    /// Grows with the setting: a 30-second blend plus its arming window would
    /// otherwise swallow a 45-second track whole.
    private var minimumTrackLength: Double { max(45, seconds + 30) }

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

    /// What Prism has heard of a track: seconds per beat, and where a beat
    /// falls in the track's own time. Set by the model from `TempoMemory`.
    var heardBeat: ((String) -> TempoMemory.Heard?)?
    /// The beat grid being heard right now — seconds per beat and when one
    /// landed. Taken at the top of a blend, while it is still the outgoing
    /// song's alone.
    var liveBeat: (() -> (period: Double, beatAt: Date, downbeatAt: Date?)?)?
    private var alignTask: Task<Void, Never>?
    /// True only during the swap, when the player legitimately stops for a
    /// moment. Outside it, a *paused* player means the user pressed pause.
    ///
    /// Only `.paused` — not merely "not playing". `PlaybackState.isPlaying` is
    /// false for `.ended` too, and the outgoing track reaching its end is the
    /// single most predictable event in a crossfade: the fade is armed to finish
    /// exactly there. Treating it as a pause cancelled the mix at t 0.99, every
    /// time, a heartbeat before the handover — and `cancelFade` then restored
    /// the main player to full volume on a track YouTube had already advanced
    /// to 0:00, which is the "it jumps back to the start of the song" bug.
    private var handingOver = false
    /// True from the instant a cut silences the main player until the handover
    /// takes over. Without it the "paused mid-fade" guard below cancels the
    /// transition it is halfway through: a cut *deliberately* stops the
    /// outgoing track, and the platform stops it a second time when the shadow
    /// starts, so the snapshot legitimately reports "not playing" at exactly
    /// the moment the cut is working correctly. Measured — the lead-in ran its
    /// full eight seconds and then died on its own switch.
    private var cutting = false
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

        // Repeat-one means the next thing to play is this track again, so there
        // is nothing to cross into. Without this the transition armed the next
        // *queue* entry and handed over to it, and the track advanced instead of
        // repeating — the mode looked broken while it was in fact being
        // overruled. Verified: with ONE set and six seconds left, playback moved
        // to a different video and fade.log recorded a completed handover.
        //
        // Checked before the in-flight branch as well, so switching to ONE
        // during a fade abandons it rather than letting it land.
        if (snap.repeatMode ?? "NONE") == "ONE" {
            // cancelFade rather than just clearing the arm: it also tears down a
            // shadow that is already loaded and holding a second player.
            cancelFade("repeat one — the track is not going anywhere")
            return
        }

        if fading {
            // The user skipped, or something else moved the player out from
            // under us. Left alone the ramp would keep pulling the main
            // player's volume down on a track that is not the one being faded,
            // and it would never reach the handover that puts it back.
            let id = snap.track?.videoId
            // Not while a cut is in flight. A cut ends the outgoing track by
            // design and then moves the main player onto the next one, so the
            // track *is* expected to change — and YouTube often auto-advances
            // at the same moment, landing on something that is neither the
            // outgoing nor the armed id for a tick or two. Cancelling there
            // threw away a handover that had already placed the cut correctly:
            // measured, the switch itself was clean at 92ms and the alignment
            // that follows it was abandoned a moment later.
            if !cutting && !handingOver && id != fadingFrom && id != armedFor {
                cancelFade("track changed under the fade")
            } else if !handingOver && !cutting && snap.playback == .paused {
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
        // A switch starts its sneak-in up to a dozen seconds before the switch
        // itself, which is `seconds` before the end — so it arms that much
        // earlier too.
        let armLead = style == .switchCut ? seconds + 30 : seconds + 18
        if remaining < armLead, armedFor != next.videoId {
            trace("[FADE_MATH] arming \(next.title) — \(String(format: "%.1f", remaining))s left")
            arm(next.videoId)
        }

        // Plan before firing, because the plan decides *when* to fire. A fade
        // that fires at the slider's length but only runs for the planned
        // length ends early and takes the last seconds of the outgoing track
        // with it — an 84.9 BPM pair plans 2.83s, so a 6s trigger cut three
        // seconds off the end of every song.
        if style == .switchCut {
            if armedFor == next.videoId, pendingPlan == nil {
                pendingPlan = makeSwitchPlan(outgoing: track.videoId)
            }
            // Scheduled once, a little ahead, onto the outgoing song's bar
            // line nearest the moment `seconds` before its end.
            if let plan = pendingPlan, scheduledStart == nil, shadowReady,
               fadingFrom != track.videoId, remaining - seconds <= plan.duration + 2 {
                scheduleSwitch(from: track.videoId, plan: plan,
                               target: Date().addingTimeInterval(max(remaining - seconds, 0)),
                               volume: snap.volume)
            }
            return
        }

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
                    // A blend proves readiness by *playing* the shadow. A cut
                    // must not: only one webview may have audio at a time, so
                    // starting the shadow here silently paused the main player
                    // mid-track — measured, it stopped dead at 228.8s of 252.2
                    // and the transition then never fired, because a paused
                    // track's remaining time never falls. Loading is enough to
                    // prove the shadow is good; playing it is the cut itself.
                    let probe = Self.mode == .cut
                        ? """
                        (function(){
                          var p = document.querySelector('#movie_player');
                          if (!p || !p.getPlayerState) return 'none';
                          try {
                            // Pause on every poll, not once at the end. The
                            // shadow's page autoplays as soon as it loads, and
                            // that alone takes the audio session away from the
                            // main player — measured, the outgoing track went
                            // silent at 228.3s during arming, long before any
                            // cut. Muting is not enough; it has to be stopped.
                            p.mute(); p.setVolume(0); p.pauseVideo();
                            var d = p.getDuration ? p.getDuration() : 0;
                            var f = p.getVideoLoadedFraction ? p.getVideoLoadedFraction() : 0;
                            return (d > 0 && f > 0.01 ? 'ready' : 'wait') + ':' + d + ':' + f;
                          } catch (e) { return 'err ' + e.message; }
                        })()
                        """
                        : """
                        (function(){
                          var p = document.querySelector('#movie_player');
                          if (!p || !p.getPlayerState) return 'none';
                          try {
                            p.mute(); p.setVolume(0); p.playVideo();
                            return String(p.getPlayerState()) + ':' + String(p.getCurrentTime());
                          } catch (e) { return 'err ' + e.message; }
                        })()
                        """
                    let state = await js(probe) ?? "none"

                    // 1 = playing, 3 = buffering. Either means audio is flowing
                    // and the fade-in will be heard. 5 = cued but stalled,
                    // 2 = paused, 0/-1 = never started; an unplayable or
                    // region-blocked track sits in those forever, which the
                    // attempt cap catches.
                    if state.hasPrefix("ready") || state.hasPrefix("1") || state.hasPrefix("3") {
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
            switch Self.mode {
            case .blend: await runFade(seconds: fade, target: target, ramp: plan.tempoRamp)
            case .cut:   await runCut(leadIn: fade, target: target, ramp: plan.tempoRamp)
            }
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
        let a = analysisForPlan(outgoing, duration: engine.snapshot.duration, live: true)
        let b = armedFor.flatMap { analysisForPlan($0, duration: 0, live: false) }
        guard let a, let b else {
            let missing = [a == nil ? "the outgoing track" : nil, b == nil ? "the incoming track" : nil]
                .compactMap { $0 }.joined(separator: " or ")
            return .fallback(seconds: seconds, reason: "no tempo known for \(missing); using the set length")
        }
        return AutoMix.plan(from: a, to: b, preferred: seconds,
                            capabilities: capabilities,
                            maxDuration: min(Self.maximumBlend, max(remaining, 1)),
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
        fadeClock = (began, fade, fadingFrom)
        if let entry = switchEntry, let at = switchAt {
            startEntryAlignment(began: began, rate: ramp?.incomingRate ?? 1, entry: entry, switchAt: at)
        } else {
            startBeatAlignment(began: began, rate: ramp?.incomingRate ?? 1)
        }
        var lastTraced = -1.0
        while true {
            if Task.isCancelled { return }
            let elapsed = Date().timeIntervalSince(began)
            let t = min(elapsed / fade, 1)

            // Ducked equal-power. Plain equal-power parks both songs at -3 dB
            // through the whole middle of the blend, so for several seconds
            // neither is in front and the overlap reads as two records at once.
            // This pulls the outgoing track down harder and derives the
            // incoming gain from it, so the total power is still exactly 1 and
            // the new track is simply in front sooner.
            // A switch lands its cut on the bar line itself rather than on
            // whichever 40ms tick comes after it.
            if let at = switchAt, at.timeIntervalSinceNow < 0.05 {
                let wait = at.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                engine.setVolume(0)
                fire("(function(){var p=document.querySelector('#movie_player'); if(p) p.setVolume(\(target));})()")
                trace(String(format: "[SWITCH] cut at %+.0f ms from the bar line",
                             Date().timeIntervalSince(at) * 1000))
                break
            }

            let (out, into) = (style == .switchCut ? BlendCurve.switchCut : .duckedPower).gains(at: t)

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

            // The gain ramp must never wait on a diagnostic.
            //
            // This used to `await shadowClock()` right here, on the critical
            // path, every half second — and a slow round trip into the shadow
            // webview stalled the whole loop with it. Caught in a real blend:
            // the fade sampled three times across eight seconds (t 0.00, 0.08,
            // then 1.00) instead of every 40 ms, so the "ramp" was three steps
            // and only the first of three tempo bends ever fired. Off the path
            // entirely now, and skipped outright when nothing is logging.
            if logHandle != nil, elapsed - lastTraced > 0.5 {
                lastTraced = elapsed
                let (tNow, outNow, intoNow) = (t, out, into)
                Task { [weak self] in
                    guard let self else { return }
                    let shadowNow = await shadowClock()
                    trace(String(format: "[FADE_MATH] t %.2f  out %.3f  in %.3f  shadow @ %.2f",
                                 tNow, outNow, intoNow, shadowNow))
                }
            }
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(40))
        }

        if Task.isCancelled { return }
        await handover(target: target, elapsedFade: Date().timeIntervalSince(began),
                       shadowRate: ramp?.incomingRate ?? 1)
    }

    /// A transition for a platform that cannot fade.
    ///
    /// Same shape as `runFade` with the gain taken out, and one deliberate
    /// difference in timing: the shadow is **not** started at the top. On iOS
    /// only one webview may have audio at a time — measured, starting the
    /// shadow paused the main player mid-track — so an early start would not
    /// overlap, it would simply end the outgoing song early. Here that rule is
    /// the mechanism rather than the obstacle: the shadow stays paused and
    /// buffered through the lead-in, and the one `playVideo()` that starts it
    /// *is* the cut.
    ///
    /// The lead-in is the part worth hearing. The plan's duration is spent
    /// bending the outgoing track's tempo toward the incoming one, so the two
    /// grooves converge before the switch instead of colliding at it. In a
    /// blend those bends are placed late and hidden under the incoming track;
    /// here nothing masks them, which is the point — the old song audibly
    /// leans into the new one.
    private func runCut(leadIn: Double, target: Double, ramp: TempoRamp?) async {
        var pendingSteps = ramp?.outgoingSteps ?? []
        let began = Date()
        var lastTraced = -1.0

        while true {
            if Task.isCancelled { return }
            let elapsed = Date().timeIntervalSince(began)
            let t = min(elapsed / leadIn, 1)

            if let step = pendingSteps.first, t >= step.at {
                pendingSteps.removeFirst()
                engine.setPlaybackRate(step.rate)
                trace(String(format: "[CUT] lead-in bend at t %.2f → ×%.4f", t, step.rate))
            }

            if elapsed - lastTraced > 0.5 {
                lastTraced = elapsed
                trace(String(format: "[CUT] lead-in t %.2f", t))
            }
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(40))
        }

        if Task.isCancelled { return }

        // The cut. Silence the main first: if the shadow is started first, the
        // platform stops the main for us and the order of the two silences
        // becomes the platform's decision rather than Prism's.
        let cutAt = Date()
        cutting = true
        engine.mute()
        fire("(function(){var p=document.querySelector('#movie_player'); if(p){p.unMute(); p.setVolume(100); p.playVideo();}})()")

        // How long the shadow takes to make a sound is the size of the hole in
        // the music, so it is measured rather than assumed.
        var heard = -1.0
        for _ in 0..<40 {
            if Task.isCancelled { return }
            if await shadowClock() > 0.05 {
                heard = Date().timeIntervalSince(cutAt)
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        trace(heard >= 0
              ? String(format: "[CUT] shadow audible %.0f ms after the cut", heard * 1000)
              : "[CUT] shadow never started — the next track will load normally")

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

        // Only skip if YouTube has not already done it for us, and *wait* to
        // find out.
        //
        // The outgoing track reaches its natural end at exactly the moment the
        // fade finishes, so YouTube is usually mid-advance right here. This used
        // to read `snapshot.track`, which is pushed about once a second — far
        // too coarse for the seam. It was almost always still naming the
        // outgoing track, so `next()` was called on top of an advance already in
        // flight and playback landed two tracks on. That is the whole "it skips
        // songs in an album" report.
        //
        // The wait costs nothing audible: the shadow is the one being heard
        // throughout, and the main player is muted until the join.
        var advanced = false
        for _ in 0..<14 {
            if Task.isCancelled { return }
            if await engine.liveTrackId() == expected { advanced = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        if advanced {
            trace("[FADE_MATH] YouTube advanced on its own; not skipping")
        } else {
            trace("[FADE_MATH] no advance after 1.4s; skipping to the armed track")
            engine.noteQueueCause("crossfade handover")
            engine.next()
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
        switch Self.mode {
        case .blend:
            // The join is kept short enough that the two copies cannot drift
            // apart inside it.
            //
            // They are the same audio at the same position, but not at the same
            // *speed*: the shadow is still running at the bend's `shadowRate`
            // while the main player has been reset to 1.0. Overlapping them for
            // a fixed 144 ms therefore pulled two identical signals apart by
            // `|rate - 1| × 144 ms` — 8.6 ms at a 6% bend, 17 ms at 12% — and
            // two copies of the same sound a few milliseconds apart is a comb
            // filter. That is the small bump at the end of a mix.
            //
            // So the overlap is budgeted by drift rather than fixed: at most
            // ~4 ms of separation, which is short enough to stay out of comb
            // territory, and never longer than the 144 ms that hides alignment
            // error nor shorter than 36 ms, which would be a cut.
            let mismatch = max(abs(shadowRate - 1), 0.001)
            let joinSeconds = min(0.144, max(0.036, 0.004 / mismatch))
            let stepSeconds = 0.018
            let blendSteps = max(2, Int((joinSeconds / stepSeconds).rounded()))
            trace(String(format: "[FADE_MATH] join over %.0f ms in %d steps (rate ×%.4f)",
                         joinSeconds * 1000, blendSteps, shadowRate))
            for step in 1...blendSteps {
                if Task.isCancelled { return }
                let a = Double(step) / Double(blendSteps)
                engine.setVolume(target * a)
                fire("(function(){var p=document.querySelector('#movie_player'); if(p) p.setVolume(\(target * (1 - a)));})()")
                try? await Task.sleep(for: .seconds(stepSeconds))
            }
        case .cut:
            // No ramp to run — the gains are inert here. Both players are on
            // the same track within the alignment band checked above, so
            // handing back is a switch between two copies of the same audio at
            // the same position. Silence the shadow explicitly rather than
            // leaving it to the platform's one-player rule, so which of them is
            // audible is never ambiguous.
            engine.setVolume(target)
            fire("(function(){var p=document.querySelector('#movie_player'); if(p){p.mute(); p.pauseVideo();}})()")
            trace(String(format: "[CUT] handed back to the main player, drift %+.3f", drift))
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
        cutting = false
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
        fadeClock = nil
        alignTask?.cancel()
        alignTask = nil
        scheduledStart?.cancel()
        scheduledStart = nil
        switchAt = nil
        switchEntry = nil
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

    // MARK: Switch

    /// The switch's plan: tempo, how long the sneak-in lasts, and where the
    /// incoming song starts so its drop arrives on the switch.
    ///
    /// No outgoing bend here, unlike a blend: every rate change freezes the
    /// track it is applied to for about half a second, and in a switch the
    /// outgoing song is in front until the very end. The incoming track takes
    /// all of it, set while it is still paused and silent. Tempos may meet at
    /// 3:2 as well as 1:1 and 2:1 — two beats of one against three of the
    /// other, the way a 103 BPM track switches into a 155 BPM one.
    private func makeSwitchPlan(outgoing: String) -> TransitionPlan {
        var plan = TransitionPlan.fallback(seconds: 4, reason: "switch")
        plan.curve = .switchCut
        plan.notes = []
        switchEntry = nil

        let aBPM = analysisForPlan(outgoing, duration: engine.snapshot.duration, live: true)?.bpm
        let bBPM = armedFor.flatMap { analysisForPlan($0, duration: 0, live: false)?.bpm }
        var rate = 1.0, matched = false
        if let a = aBPM, let b = bBPM {
            let m = Tempo.match(from: a, to: b, maxPercent: TempoRampPlanner.maxIncomingPercent,
                                allowTriplet: true)
            if m.acceptable {
                rate = m.rate
                matched = true
                plan.notes.append(String(format: "switch: %.1f → %.1f BPM, incoming ×%.4f%@", a, b, rate,
                                         m.triplet ? " (3:2 lock)" : m.foldedOctave ? " (half/double time)" : ""))
            } else {
                plan.notes.append(String(format: "switch: %.1f and %.1f BPM don't lock; a short switch", a, b))
            }
        } else {
            plan.notes.append("switch: a tempo is unknown; a short switch on the beat")
        }
        // Four bars of sneak-in when the grooves lock — long enough to hear
        // the new song arrive under the old one — and one bar when they don't,
        // so two clashing grooves barely meet.
        let beat = aBPM.map { 60 / $0 } ?? 0.5
        let beats = matched ? 16 : 4
        plan.beats = beats
        plan.duration = Double(beats) * beat
        if matched, abs(rate - 1) > 1e-4, let a = aBPM {
            plan.tempoRamp = TempoRamp(meetingBPM: a, outgoingRate: 1, incomingRate: rate, outgoingSteps: [])
        }

        // Where the incoming song enters: its drop if heard, else its first
        // bar line far enough in to leave room for the sneak-in.
        let rowLength = nextTrack(in: engine.snapshot)?.durationText.flatMap(Self.seconds)
        if let id = armedFor, let heard = heardBeat?(id),
           // Only the recording that was heard: another version of the song
           // can have a longer intro, and its drop somewhere else.
           heard.direct == true || zip(heard.duration.map { [$0] } ?? [], rowLength.map { [$0] } ?? [])
               .contains(where: { abs($0 - $1) < 1.5 }) {
            let bar = heard.period * 4
            var entry = heard.dropAt
            if entry == nil, let phase = heard.barPhase {
                let lead = plan.duration * rate
                entry = phase + ((lead - phase) / bar).rounded(.up) * bar
            }
            if let e = entry {
                plan.startOffsetForIncoming = SwitchTiming.incomingStart(entry: e, overlap: plan.duration,
                                                                         rate: rate, bar: bar)
                switchEntry = plan.startOffsetForIncoming + plan.duration * rate
                plan.notes.append(String(format: "incoming enters at %.1fs%@, starting from %.1fs",
                                         switchEntry!, heard.dropAt != nil ? " (its drop)" : " (a bar line)",
                                         plan.startOffsetForIncoming))
            }
        }
        return plan
    }

    /// "3:45" or "1:02:03" in seconds.
    private static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Puts the switch on the outgoing song's bar line nearest `target`, and
    /// starts the sneak-in that far ahead of it.
    private func scheduleSwitch(from id: String, plan: TransitionPlan, target: Date, volume: Double) {
        let now = Date()
        var at = target.timeIntervalSinceReferenceDate
        if let grid = liveBeat?() {
            let down = grid.downbeatAt ?? grid.beatAt
            at = SwitchTiming.switchTime(now: now.timeIntervalSinceReferenceDate, target: at,
                                         downbeat: down.timeIntervalSinceReferenceDate,
                                         bar: grid.period * (grid.downbeatAt != nil ? 4 : 1),
                                         overlap: plan.duration)
            trace(String(format: "[SWITCH] on %@ in %.2fs", grid.downbeatAt != nil ? "a bar line" : "a beat",
                         at - now.timeIntervalSinceReferenceDate))
        } else {
            at = max(at, now.timeIntervalSinceReferenceDate + plan.duration)
            trace("[SWITCH] no beat heard — switching on time alone")
        }
        let switchDate = Date(timeIntervalSinceReferenceDate: at)
        switchAt = switchDate
        let startAt = switchDate.addingTimeInterval(-plan.duration)
        scheduledStart = Task { [weak self] in
            let wait = startAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled, !self.fading, self.fadingFrom != id else { return }
            let snap = self.engine.snapshot
            self.start(from: id, remaining: max(snap.duration - self.engine.smoothTime(), 0.5), volume: volume)
        }
    }

    /// Lands the incoming song's entry — its drop, or a bar line — exactly on
    /// the switch. The same two-seek nudge as beat alignment, measured against
    /// the switch moment itself rather than the nearest beat, so it also
    /// fixes a start that came in a beat or two out. Early in the sneak-in,
    /// while the new song is quiet underneath.
    private func startEntryAlignment(began: Date, rate: Double, entry: Double, switchAt: Date) {
        alignTask?.cancel()
        alignTask = Task { [weak self] in
            guard let self else { return }
            for (pass, due) in [0.5, 1.5, 2.5].enumerated() {
                let wait = began.addingTimeInterval(due).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                // Leave the last second before the switch alone.
                guard !Task.isCancelled, self.fading, switchAt.timeIntervalSinceNow > 1,
                      let r = await self.shadowReading() else { return }
                let arrives = r.at.addingTimeInterval((entry - r.media) / rate)
                let error = arrives.timeIntervalSince(switchAt)
                self.trace(String(format: "[SWITCH] pass %d: the entry would land %+.0f ms from the switch",
                                  pass, error * 1000))
                guard pass < 2, abs(error) > 0.03 else { return }
                let shift = BeatAlign.shift(error: error, rate: rate,
                                            stall: pass == 0 ? 0 : min(max(error, 0), 0.4))
                let target = max(r.media + Date().timeIntervalSince(r.at) * rate + shift, 0)
                self.fire("(function(){var p=document.querySelector('#movie_player'); if(p) p.seekTo(\(target), true);})()")
                self.incomingOffset += shift
            }
        }
    }

    // MARK: Tempo and beats

    /// The planner's view of a track: the online lookup, with the tempo Prism
    /// has heard filled in where the lookup has none. The lookup answers
    /// `bpm: 0` for most tracks, which is why most blends were plain fades.
    /// `live`: the track is the one playing, so the beat being heard right
    /// now is its tempo even if it has not been kept yet.
    private func analysisForPlan(_ id: String, duration: Double, live: Bool) -> TrackAnalysis? {
        let looked = analysis.cached(id)
        let period = heardBeat?(id)?.period ?? (live ? liveBeat?()?.period : nil)
        guard let period, period > 0.2 else {
            return looked?.bpm == nil ? nil : looked
        }
        var a = looked ?? TrackAnalysis(id: id, duration: duration)
        if a.bpm == nil || a.confidence < 0.8 {
            a.bpm = 60 / period
            a.confidence = max(a.confidence, 0.8)
        }
        return a
    }

    /// Lines the incoming track's beats up with the outgoing track's, early in
    /// the blend while the new song is still quiet under the old one.
    ///
    /// Tempo matching alone makes the two pulses the same speed but leaves
    /// them wherever they happened to start, which is the "two songs at once"
    /// sound. This reads where the incoming track actually is, compares its
    /// beats (from `TempoMemory`) against the outgoing track's live beat grid,
    /// and nudges it with a seek — twice, because a seek holds the track
    /// silent for a moment and so lands it that much late; the second pass
    /// measures what the first one cost and jumps that much further. Both land
    /// inside the first two and a half seconds, under the outgoing track.
    private func startBeatAlignment(began: Date, rate: Double) {
        alignTask?.cancel()
        guard let grid = liveBeat?() else {
            trace("[BEATS] not aligned — no steady beat heard in the outgoing track")
            return
        }
        guard let id = armedFor else { return }
        alignTask = Task { [weak self] in
            await self?.alignBeats(began: began, rate: rate,
                                   grid: (grid.period, grid.beatAt), armed: id)
        }
    }

    private func alignBeats(began: Date, rate: Double,
                            grid: (period: Double, beatAt: Date), armed: String) async {
        // Which recording the shadow is really playing, and how long it is —
        // YouTube can load another version than the queue row names.
        let wait0 = began.addingTimeInterval(0.6).timeIntervalSinceNow
        if wait0 > 0 { try? await Task.sleep(for: .seconds(wait0)) }
        guard !Task.isCancelled, fading, let info = await shadowInfo() else { return }
        guard let heard = heardBeat?(info.videoId) ?? heardBeat?(armed) else {
            trace("[BEATS] not aligned — the incoming track (\(info.videoId)) has not been heard yet")
            return
        }
        guard let phase = heard.phase,
              heard.direct == true && info.videoId == armed || heard.duration.map({ abs($0 - info.duration) < 1 }) == true
        else {
            trace(String(format: "[BEATS] not aligned — heard another version (%.0fs, this one %.0fs); tempo matched, beats not placed",
                         heard.duration ?? 0, info.duration))
            return
        }
        // The matched incoming beat must be the outgoing one, or half or
        // double it; anything else would line up one beat and miss the rest.
        let ratio = (heard.period / rate) / grid.period
        let octave = pow(2, log2(ratio).rounded())
        guard abs(ratio / octave - 1) < 0.025 else {
            trace(String(format: "[BEATS] not aligned — tempos don't match (ratio %.3f)", ratio))
            return
        }
        let period = heard.period

        func miss() async -> (error: Double, media: Double, at: Date)? {
            guard let r = await shadowReading() else { return nil }
            let e = BeatAlign.error(incomingMedia: r.media, readAt: r.at.timeIntervalSinceReferenceDate,
                                    incomingPhase: phase, incomingPeriod: period, rate: rate,
                                    outgoingBeat: grid.beatAt.timeIntervalSinceReferenceDate,
                                    outgoingPeriod: grid.period)
            return (e, r.media, r.at)
        }
        for (pass, due) in [0.9, 2.1, 3.3].enumerated() {
            let wait = began.addingTimeInterval(due).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, fading, let m = await miss() else { return }
            trace(String(format: "[BEATS] pass %d: incoming beats %+.0f ms off the outgoing grid",
                         pass, m.error * 1000))
            // The third reading only reports how it ended.
            guard pass < 2, abs(m.error) > 0.03 else { return }
            // After a seek, a late residual is mostly that seek's stall; expect
            // the next to cost as much.
            let shift = BeatAlign.shift(error: m.error, rate: rate,
                                        stall: pass == 0 ? 0 : min(max(m.error, 0), 0.4))
            let target = max(m.media + Date().timeIntervalSince(m.at) * rate + shift, 0)
            fire("(function(){var p=document.querySelector('#movie_player'); if(p) p.seekTo(\(target), true);})()")
            incomingOffset += shift
        }
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

    /// The shadow's position and the wall-clock moment it was read, from the
    /// same instant in the page, so the reply's trip back does not count.
    private func shadowReading() async -> (media: Double, at: Date)? {
        let raw = await js("(function(){var v=document.querySelector('#movie_player video');return v&&!v.paused?(v.currentTime+'|'+(performance.timeOrigin+performance.now())):'';})()")
        let parts = (raw ?? "").split(separator: "|").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], Date(timeIntervalSince1970: parts[1] / 1000))
    }

    /// The video the shadow is actually playing, and its length.
    private func shadowInfo() async -> (videoId: String, duration: Double)? {
        let raw = await js("(function(){var p=document.querySelector('#movie_player');if(!p||!p.getVideoData)return '';var d=p.getVideoData();return (d&&d.video_id?d.video_id:'')+'|'+(p.getDuration?p.getDuration():0);})()")
        let parts = (raw ?? "").split(separator: "|")
        guard parts.count == 2, !parts[0].isEmpty, let d = Double(parts[1]) else { return nil }
        return (String(parts[0]), d)
    }

    private func shadowClock() async -> Double {
        let raw = await js("(function(){var p=document.querySelector('#movie_player');return p?String(p.getCurrentTime()):'';})()")
        return Double(raw ?? "") ?? -1
    }
}
