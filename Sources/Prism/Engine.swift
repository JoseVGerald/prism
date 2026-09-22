import SwiftUI
import WebKit
import Observation

/// Owns the headless `music.youtube.com` webview and exposes it to SwiftUI as
/// plain observable state. Nothing above this layer knows the web is involved.
@MainActor
@Observable
final class Engine: NSObject {

    // MARK: Observable state

    var snapshot = EngineSnapshot(
        ready: false, signedIn: false, state: -1, currentTime: 0, duration: 0,
        volume: 100, muted: false, repeatMode: "NONE", shuffled: false,
        track: nil, queue: [], queueIndex: -1, undoLabel: nil)

    /// True until the engine reports the player exists.
    var isBooting = true
    /// Raised over the UI so the user can complete Google sign-in.
    var showingEngine = false
    var lastError: String?

    /// Called after every navigation, once the bridge is back in place.
    var onDocumentReady: (() -> Void)?

    /// Attributes a queue change Swift is about to cause, so the trace can name
    /// it rather than blaming YouTube. See `queueChange` in the bridge.
    func noteQueueCause(_ label: String) { run("noteQueueCause", [label]) }

    /// While the user drags the scrubber we stop letting engine ticks fight them.
    var scrubOverride: Double?

    var displayTime: Double { scrubOverride ?? snapshot.currentTime }

    /// When the current snapshot arrived.
    private(set) var snapshotAt = Date()

    /// Playback position extrapolated between snapshots.
    ///
    /// Snapshots are pushed when the whole second changes, so `displayTime`
    /// moves in one-second lurches — fine for a scrubber, useless for lyrics
    /// that fill word by word. Between pushes this runs the clock forward
    /// locally while playing, capped at 1.5s so a stalled bridge cannot let it
    /// wander far from the truth.
    func smoothTime(at date: Date = Date()) -> Double {
        if let scrubOverride { return scrubOverride }
        let limit = snapshot.duration > 0 ? snapshot.duration : .greatestFiniteMagnitude
        // The precise clock, while it is running and fresh: an exact reading
        // from the page every 250ms or sooner, carried forward at the playback
        // rate the tempo glide may have set.
        if let c = clock, c.videoId == snapshot.track?.videoId,
           date.timeIntervalSince(c.at) < 1 {
            guard c.playing else { return min(c.t, limit) }
            return min(c.t + max(date.timeIntervalSince(c.at), 0) * c.rate, limit)
        }
        let t = snapshot.currentTime
        guard snapshot.playback == .playing else { return t }
        let ahead = min(max(date.timeIntervalSince(snapshotAt), 0), 1.5)
        return min(t + ahead, limit)
    }

    /// The page's latest precise reading. Not observed: it changes ten times a
    /// second, and the views that want it sample it from their own timelines.
    @ObservationIgnored private var clock: (t: Double, at: Date, rate: Double,
                                            playing: Bool, videoId: String?)?
    @ObservationIgnored private var clockHolders: Set<String> = []

    /// Asks the page for the precise clock on behalf of `who`, or lets go. The
    /// page listens to the video only while at least one holder wants it.
    func needPreciseClock(_ who: String, _ on: Bool) {
        let before = !clockHolders.isEmpty
        if on { clockHolders.insert(who) } else { clockHolders.remove(who) }
        let after = !clockHolders.isEmpty
        guard before != after else { return }
        run("clock", [after])
        if !after { clock = nil }
    }

    /// `~/.prism-eval/track.log` under PRISM_EVAL: every change of the track
    /// the snapshot reports, to the millisecond, with the queue row it claims.
    /// The picture follows `snapshot.track`, so a wrong track on screen for a
    /// moment is a wrong track in here.
    private func logTrackChange(_ snap: EngineSnapshot) {
        guard ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1" else { return }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".prism-eval/track.log")
        let row = snap.queue.indices.contains(snap.queueIndex) ? snap.queue[snap.queueIndex] : nil
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) "
            + "\(snap.track?.videoId ?? "-") \(snap.track?.title ?? "(none)") · state \(snap.playback) "
            + "· t \(String(format: "%.2f", snap.currentTime)) · row \(snap.queueIndex) "
            + "\(row?.videoId ?? "-") \(row?.title ?? "")\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private struct ClockReading: Decodable {
        let t: Double
        let rate: Double
        let playing: Bool
        let at: Double          // ms since 1970, when the page read it
        let videoId: String?
    }

    // MARK: Web plumbing

    private(set) var webView: WKWebView!
    private var pending: [String: (Result<Data, Error>) -> Void] = [:]
    private var activityToken: NSObjectProtocol?

    override init() {
        super.init()
        buildWebView()
        preventAppNap()
        startDebugEval()
    }

    /// A console for the page, opt-in via `PRISM_EVAL=1`.
    ///
    /// Every queue mistake in this project came from inferring behaviour off
    /// screenshots instead of asking the page what it did. Drop JS in
    /// `~/.prism-eval/in.js` and the answer lands in `~/.prism-eval/out.json`.
    private func startDebugEval() {
        guard ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1" else { return }
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".prism-eval")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inURL = dir.appendingPathComponent("in.js")
        let outURL = dir.appendingPathComponent("out.json")
        try? "\(Date())".write(to: dir.appendingPathComponent("alive"),
                               atomically: true, encoding: .utf8)

        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self,
                      let js = try? String(contentsOf: inURL, encoding: .utf8),
                      !js.isEmpty else { continue }
                try? FileManager.default.removeItem(at: inURL)
                // Wrapped so `await` works and objects survive the bridge.
                let wrapped = """
                return (async () => {
                  try { return JSON.stringify(await (async () => { \(js) })()); }
                  catch (e) { return JSON.stringify({ __error: String(e) }); }
                })()
                """
                let result: String = await withCheckedContinuation { cont in
                    self.webView.callAsyncJavaScript(
                        wrapped, arguments: [:], in: nil, in: .page
                    ) { r in
                        switch r {
                        case .success(let v): cont.resume(returning: (v as? String) ?? "null")
                        case .failure(let e): cont.resume(returning: "{\"__throw\":\"\(e)\"}")
                        }
                    }
                }
                try? result.write(to: outURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Writes each accepted snapshot to `~/.prism-eval/snapshot.json`.
    ///
    /// `in.js` can ask the *page* anything, but it cannot say what Prism itself
    /// ended up believing — and the gap between the two is exactly where the
    /// bugs live. A field the bridge sends but Swift silently fails to decode
    /// looks identical, from the page, to one that works.
    private var snapshotDumpURL: URL? {
        guard ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1" else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".prism-eval/snapshot.json")
    }

    /// `~/.prism-eval/queue.log`, and only under PRISM_EVAL.
    private var queueLogURL: URL? {
        guard ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1" else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".prism-eval/queue.log")
    }

    private func logQueueChange(_ data: Data) {
        guard let url = queueLogURL,
              let envelope = try? JSONDecoder().decode(QueueTraceEnvelope.self, from: data),
              let t = envelope.trace else { return }

        let stamp = Self.logStamp.string(from: Date())
        var line = "\(stamp)  \(t.shape)\n            cause: \(t.cause)"
        if let playing = t.playing { line += "\n            playing: \(playing)" }
        if let added = t.added, !added.isEmpty { line += "\n            added: \(added.joined(separator: ", "))" }
        if let removed = t.removed, !removed.isEmpty { line += "\n            removed: \(removed.joined(separator: ", "))" }
        line += "\n"

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func dumpSnapshot(_ data: Data) {
        guard let url = snapshotDumpURL else { return }
        try? data.write(to: url)
    }

    private func buildWebView() {
        let controller = WKUserContentController()
        controller.add(self, name: "prism")
        controller.addUserScript(WKUserScript(
            source: Bridge.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .default()          // persists the Google login
        config.allowsAirPlayForMediaPlayback = true
        WKWebView.prismConfiguration(config)

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        // Without a desktop UA, YouTube Music serves a cut-down layout whose
        // player element our bridge cannot find.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = self
        webView.prismMakeTransparent()
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
    }

    /// Media playback in an occluded window is a prime App Nap target; without
    /// this the audio stutters once the app loses focus.
    private func preventAppNap() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Playing audio")
    }

    // MARK: Commands

    private func jsArgs(_ args: [Any]) -> String {
        args.map { arg -> String in
            switch arg {
            case let s as String:
                let escaped = s
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            case let b as Bool:   return b ? "true" : "false"
            case let d as Double: return String(d)
            case let i as Int:    return String(i)
            default:              return "null"
            }
        }.joined(separator: ",")
    }

    private func run(_ name: String, _ args: [Any] = []) {
        let encoded = jsArgs(args)
        let js = "window.__prism && window.__prism.cmd(\"\(name)\"\(encoded.isEmpty ? "" : "," + encoded))"
        webView.evaluateJavaScript(js)
    }

    func togglePlayPause() { run("toggle") }
    func play()            { run("play") }
    func pause()           { run("pause") }
    func next()            { run("next") }
    func previous()        { run("prev") }
    func seek(to t: Double) { run("seek", [t]) }

    /// The player's clock right now, rather than whatever the last 250ms
    /// snapshot said. Crossfade alignment needs better resolution than a tick.
    /// The id the player is *actually* on, asked directly rather than read from
    /// the snapshot. Snapshots are pushed about once a second, which is far too
    /// coarse to decide anything at the seam of a transition.
    func liveTrackId() async -> String? {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(
                "(function(){var p=document.querySelector('#movie_player');"
                + "var d=p&&p.getVideoData&&p.getVideoData();return d?String(d.video_id||''):'';})()"
            ) { value, _ in
                let id = (value as? String) ?? ""
                cont.resume(returning: id.isEmpty ? nil : id)
            }
        }
    }

    func liveTime() async -> Double {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(
                "(function(){var p=document.querySelector('#movie_player');return p?String(p.getCurrentTime()):'';})()"
            ) { value, _ in
                cont.resume(returning: Double((value as? String) ?? "") ?? -1)
            }
        }
    }

    func setVolume(_ v: Double) { run("setVolume", [v]) }
    func mute()   { run("mute") }
    func unmute() { run("unmute") }

    /// Playback tempo, with pitch preserved. 1 is the track's own speed.
    ///
    /// Resets to 1 whenever a new track loads, exactly like volume does, so
    /// anything relying on it has to re-assert after a skip.
    func setPlaybackRate(_ rate: Double) { run("setRate", [rate]) }

    /// The player's tempo right now. Needed because a track load silently puts
    /// it back to 1, and the glide has to know when that has happened.
    func liveRate() async -> Double {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(
                "(function(){var v=document.querySelector('video');return v?String(v.playbackRate):'';})()"
            ) { value, _ in
                cont.resume(returning: Double((value as? String) ?? "") ?? 1)
            }
        }
    }
    func jump(to index: Int) { run("jump", [index]) }
    func removeFromQueue(at index: Int) { run("removeAt", [index]) }
    /// `to` is the row's final resting index, not its pre-removal one.
    func moveInQueue(from: Int, to: Int) { run("moveItem", [from, to]) }
    /// Drops everything except the track that is playing.
    func clearQueue()      { run("clearQueue") }
    /// Restores the queue to how it looked before the last edit.
    func undoQueue()       { run("undoQueue") }
    func shuffleQueue()    { run("shuffle") }
    func cycleRepeat()     { run("cycleRepeat") }
    /// Plays a track. `radio` seeds a mix from it so the queue is not a dead
    /// end — without it YouTube builds a queue of exactly one, nothing follows,
    /// and crossfade has nothing to preload.
    func play(videoId: String, radio: Bool = true) { run("playVideo", [videoId, radio]) }

    /// Restyles the page so the video fills it. Tracked here so it can be
    /// re-applied after a navigation drops the injected stylesheet.
    private(set) var videoMode = false
    func setVideoMode(_ on: Bool) {
        videoMode = on
        // The page's own chrome goes on both platforms, because Prism draws its
        // own transport over the picture on both. An earlier iOS build kept it
        // — the reasoning was that YouTube's touch transport is good and two
        // transports would collide — but the result was worse than either: the
        // page's red header, its tab strip and its scrubber were all visible
        // around a video that then had nowhere to be, which is what "the music
        // video UI looks terrible" was. Prism now masks the webview down to the
        // picture alone, so anything the page draws outside the video is
        // invisible and anything it draws *over* the video has to go.
        // The third flag trims the <video> element's box down to the picture,
        // which only a phone needs — see the note in the bridge.
        #if canImport(AppKit)
        run("setVideoMode", [on, false, false])
        #else
        run("setVideoMode", [on, false, true])
        #endif
    }

    /// Switches between the song and its music video, keeping the position.
    /// See the bridge command for why this drives YouTube's own control.
    func setAVMode(video: Bool) { run("setAVMode", [video]) }

    // MARK: Signing in

    /// Google's sign-in form, with a return trip to YouTube Music once it is
    /// done. Not a mobile URL on purpose: the engine sends a desktop user agent
    /// (the mobile layout has no player element the bridge can find), and a
    /// mobile sign-in page served to a desktop UA lays out wrong.
    private static let signInURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube"
        + "&continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=en")!

    private static let homeURL = URL(string: "https://music.youtube.com")!

    /// Reveals the webview *on the sign-in form*.
    ///
    /// Showing it alone is not enough and looked like a broken button: the
    /// engine is parked on whatever page playback left it on, which is normally
    /// the player, so tapping "Sign in" revealed a music video with a "Sign in
    /// to YouTube Music, then come back" bar over it and no sign-in anywhere on
    /// screen. The page has to be navigated somewhere you can actually sign in.
    ///
    /// This is the same webview and the same `.default()` data store that
    /// playback uses, which is the point — a login completed in a second
    /// webview would leave its cookies somewhere the engine cannot see.
    func beginSignIn() {
        // Playback is about to be navigated away from, so drop out of video
        // mode first; coming back to a half-applied stylesheet leaves the
        // picture black.
        if videoMode { setVideoMode(false) }
        showingEngine = true
        webView.load(URLRequest(url: Self.signInURL))
    }

    /// Puts the engine back on YouTube Music and hides it again.
    ///
    /// Always reloads rather than only reloading on failure: a completed
    /// sign-in lands on `music.youtube.com` via the `continue` parameter, but
    /// an abandoned one leaves the webview on an accounts page with no player,
    /// and telling the two apart from the URL is guesswork. The bridge
    /// re-injects on every document, so a reload is cheap and always correct.
    func endSignIn() {
        showingEngine = false
        webView.load(URLRequest(url: Self.homeURL))
    }

    /// Re-fits the video after a layout change on our side.
    func nudgeVideoLayout() { run("nudgeVideo") }
    func playPlaylist(_ playlistId: String) { run("playPlaylist", [playlistId]) }
    func playBrowse(_ browseId: String, playlistId: String? = nil) {
        run("playBrowse", [browseId, playlistId ?? ""])
    }
    // MARK: Queries

    private func query<T: Decodable>(_ name: String, _ args: [Any], as: T.Type) async throws -> T {
        let reqId = UUID().uuidString
        let encoded = jsArgs(args)
        let js = "window.__prism && window.__prism.query(\"\(name)\",\"\(reqId)\"\(encoded.isEmpty ? "" : "," + encoded))"

        let data: Data = try await withCheckedThrowingContinuation { cont in
            pending[reqId] = { cont.resume(with: $0) }
            webView.evaluateJavaScript(js) { _, err in
                if let err {
                    self.pending.removeValue(forKey: reqId)?(.failure(err))
                }
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Reads, and optionally changes, YouTube Music's account audio quality.
    /// Pass nil to read without touching it.
    func audioQuality(set want: String?) async throws -> AudioQualityResult {
        struct Wrapper: Decodable { let result: AudioQualityResult }
        return try await query("audioQuality", [want ?? ""], as: Wrapper.self).result
    }

    /// What the player is actually pulling down right now.
    func streamQuality() async throws -> StreamQuality {
        struct Wrapper: Decodable { let result: StreamQuality }
        return try await query("streamQuality", [], as: Wrapper.self).result
    }

    func setVideoQuality(_ level: String) { run("setVideoQuality", [level]) }

    func enqueue(videoId: String, atEnd: Bool) async throws -> EnqueueResult {
        struct Wrapper: Decodable { let result: EnqueueResult }
        return try await query("enqueue", [videoId, atEnd], as: Wrapper.self).result
    }

    func download(videoId: String, remove: Bool = false) async throws -> DownloadResult {
        struct Wrapper: Decodable { let result: DownloadResult }
        return try await query("download", [videoId, remove], as: Wrapper.self).result
    }

    struct LyricsPayload: Decodable { let text: String?; let source: String?; let browseId: String? }

    func lyrics(videoId: String) async throws -> LyricsPayload {
        struct Wrapper: Decodable { let result: LyricsPayload }
        return try await query("lyrics", [videoId], as: Wrapper.self).result
    }

    func search(_ text: String, scope: SearchScope = .all) async throws -> SearchResults {
        struct Wrapper: Decodable { let results: SearchResults }
        return try await query("search", [text, scope.params ?? ""], as: Wrapper.self).results
    }

    func loadLibrary() async throws -> [LibrarySection] {
        struct Wrapper: Decodable { let sections: [LibrarySection] }
        return try await query("library", [], as: Wrapper.self).sections
    }

    func loadPlaylist(_ browseId: String) async throws -> PlaylistDetail {
        struct Wrapper: Decodable { let detail: PlaylistDetail }
        return try await query("playlist", [browseId], as: Wrapper.self).detail
    }
}

// MARK: - Incoming messages

extension Engine: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return }

        switch envelope.kind {
        case "snapshot":
            if let snap = try? JSONDecoder().decode(EngineSnapshot.self, from: data) {
                if snap.track?.videoId != snapshot.track?.videoId { logTrackChange(snap) }
                snapshot = snap
                snapshotAt = Date()
                if snap.ready { isBooting = false }
                dumpSnapshot(data)
                // A page reload forgets the clock was asked for; ask again.
                if !clockHolders.isEmpty, snap.ready,
                   clock.map({ Date().timeIntervalSince($0.at) > 2 }) ?? true {
                    run("clock", [true])
                }
            }
        case "clock":
            if let r = try? JSONDecoder().decode(ClockReading.self, from: data) {
                clock = (r.t, Date(timeIntervalSince1970: r.at / 1000), r.rate,
                         r.playing, r.videoId)
            }
        case "queueChange":
            logQueueChange(data)
        case "search", "library", "playlist", "enqueue", "download", "lyrics",
             "audioQuality", "streamQuality":
            if let id = envelope.requestId {
                pending.removeValue(forKey: id)?(.success(data))
            }
        case "error":
            lastError = envelope.message
            if let id = envelope.requestId {
                pending.removeValue(forKey: id)?(
                    .failure(EngineError.bridge(envelope.message ?? "unknown")))
            }
        default:
            break
        }
    }

    private struct Envelope: Decodable {
        let kind: String
        let requestId: String?
        let message: String?
    }
}

extension Engine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The bridge re-injects itself on every document, but a nudge makes the
        // first paint arrive without waiting for the 250ms tick.
        webView.evaluateJavaScript("window.__prism && window.__prism.ping()")
        // The injected stylesheet does not survive navigation.
        if videoMode { setVideoMode(true) }
        // Neither does the bridge's video-quality preference — a fresh document
        // starts on 'auto'. Whoever owns the setting re-states it here.
        if queueLogURL != nil { run("setQueueTrace", [true]) }
        onDocumentReady?()
    }
}

enum EngineError: LocalizedError {
    case bridge(String)
    var errorDescription: String? {
        switch self { case .bridge(let m): return m }
    }
}
