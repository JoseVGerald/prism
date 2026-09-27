import SwiftUI
import Observation
#if canImport(AutoMixCore)
import AutoMixCore
#endif
#if canImport(AppKit)
import CoreGraphics
#endif

enum Route: Hashable {
    case forYou
    case nowPlaying
    case search
    case library
    case dashboard
    case downloads
    case detail(browseId: String, title: String)
}

@MainActor
@Observable
final class AppModel {
    let engine = Engine()
    let history = History()
    #if canImport(AppKit)
    /// Output switching is CoreAudio's default-device API, which iOS does not
    /// expose — routing there belongs to the system and to AirPlay, not to us.
    let audio = AudioOutput()
    #endif
    let scrobbler = Scrobbler()
    let downloads = DownloadLog()
    let tempoMemory = TempoMemory()

    /// Progress and outcome of a Takeout import, for the dashboard to show.
    var importStatus: String?
    var importing = false
    /// Last track announced to Last.fm, so "now playing" is sent once per track
    /// rather than on every snapshot.
    private var lastAnnounced: String?

    var route: Route = .nowPlaying {
        didSet {
            // Leaving the detail pages by any route other than Back — a sidebar
            // click, the wordmark, a queue jump — ends that trail. Without this
            // the stack survived, and the *next* detail page opened inherited
            // it: search, open an artist, open one of its albums, click Search
            // in the sidebar, search again, open an artist, press Back — and
            // Back walked into the album from the previous journey instead of
            // returning to the search results. It looked like Back was broken
            // when it was faithfully unwinding a trail that should not still
            // have existed.
            if case .detail = route {} else { detailStack.removeAll() }
        }
    }
    var showQueue = true
    /// Raised by the Settings menu; the root view presents the panel.
    var showSettings = false

    /// Where the current detail page was opened from, and the trail of detail
    /// pages behind it — an artist leads to an album, which should come back to
    /// the artist rather than to wherever the journey started.
    private(set) var detailOrigin: Route = .library
    private var detailStack: [(browseId: String, title: String)] = []

    /// Steps back one level: to the previous detail page if there is one, and
    /// otherwise to whatever view the first detail was opened from.
    func closeDetail() {
        if let previous = detailStack.popLast() {
            route = .detail(browseId: previous.browseId, title: previous.title)
            detail = nil
            detailLoading = true
            Task {
                do { detail = try await engine.loadPlaylist(previous.browseId) }
                catch { status = "Could not reopen \(previous.title)" }
                detailLoading = false
            }
        } else {
            route = detailOrigin
        }
    }

    /// The For You page is the landing view the first time Prism ever runs, and
    /// after that it is one click on the wordmark away.
    private static let seenKey = "prism.hasLaunched"

    // Lyrics
    var lyricsMode = false
    var lyrics: Lyrics?
    var lyricsLoading = false
    private var lyricsTask: Task<Void, Never>?
    private var lyricsFor: String?

    private var nowPlaying: NowPlaying?
    let transitions: Transitions
    let quality: QualitySettings
    let ambient = AmbientSettings()

    #if canImport(AppKit)
    /// The music as the light hears it. Capture runs only while something that
    /// uses it holds it open — see `LiveAudio.set`.
    let liveAudio = LiveAudio()
    #endif

    /// Where the light reads the music from, on platforms that can hear it.
    /// What the equalizers listen to: the live audio, unless turned off.
    var equalizerAudio: (any AudioBandsSource)? {
        ambient.equalizersHear ? audioSource : nil
    }

    var audioSource: (any AudioBandsSource)? {
        #if canImport(AppKit)
        return liveAudio
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    /// The full-screen ambient surface. macOS only: it is a window, and iOS
    /// has nothing for it to cover.
    private var ambientPanel: AmbientPanelController!
    private var idleTimer: Task<Void, Never>?
    #endif

    /// The notch island. Not a toggle — it is simply on for the whole session
    /// on a Mac that has a notch, and shows nothing at all when no track is
    /// loaded, so an idle notch looks like stock macOS.
    #if canImport(AppKit)
    private var notch: NotchController!
    #endif

    #if canImport(AppKit)
    /// Debug-only system-audio meter; see AudioProbe. ScreenCaptureKit is
    /// macOS-only, and there is no iOS route to another process's audio.
    private let probe = AudioProbe()
    #endif

    #if canImport(AppKit)
    var notchAvailable: Bool { NotchController.available }
    #else
    var notchAvailable: Bool { false }
    #endif

    /// The panel belongs to this window's session, so it goes when the window
    /// does rather than stranding an island with no way back.
    func closeFloating() {
        #if canImport(AppKit)
        notch.close()
        #endif
    }

    init() {
        transitions = Transitions(engine: engine)
        transitions.heardBeat = { [tempoMemory] id in tempoMemory.heard(id) }
        quality = QualitySettings(engine: engine)
        nowPlaying = NowPlaying(engine: engine)
        engine.onDocumentReady = { [quality] in quality.applyToEngine() }
        #if canImport(AppKit)
        notch = NotchController(model: self)
        notch.open()
        probe.startIfEnabled()
        ambientPanel = AmbientPanelController(model: self)
        startIdleWatch()
        transitions.liveBeat = { [liveAudio] in
            guard let p = liveAudio.bands.tempo, let at = liveAudio.bands.beatAt else { return nil }
            return (p, at, liveAudio.bands.downbeatAt)
        }
        #endif
        if !UserDefaults.standard.bool(forKey: Self.seenKey) {
            route = .forYou
            UserDefaults.standard.set(true, forKey: Self.seenKey)
        }

        // Scrobble off the log, not off the snapshot: History already decides
        // when a listen counts, and hanging this there means a play is sent
        // once, at the end, with the time actually heard.
        history.onPlay = { [weak self] play, length in
            guard let self else { return }
            Task { await self.scrobbler.scrobble(play, trackLength: length) }
        }
        // Anything stranded by a dropped connection or a quit goes out now.
        Task { await scrobbler.flushPending() }

        // Import without the open panel, so the parser can be exercised against
        // a real export from a script. Same spirit as `PRISM_EVAL`.
        if let path = ProcessInfo.processInfo.environment["PRISM_IMPORT"] {
            importTakeout(from: URL(fileURLWithPath: path))
        }
    }

    // MARK: Stats from elsewhere

    /// Reads a Google Takeout export and folds it into the log.
    ///
    /// Kept off the main actor: a real export is tens of megabytes and decoding
    /// it on the UI thread freezes the window for seconds.
    func importTakeout(from url: URL) {
        guard !importing else { return }
        importing = true
        importStatus = "Reading…"

        Task {
            do {
                let (plays, summary) = try await Task.detached(priority: .userInitiated) {
                    try TakeoutImport.read(url)
                }.value

                let added = history.merge(plays)
                importing = false

                let span: String = {
                    guard let first = summary.earliest else { return "" }
                    let f = DateFormatter()
                    f.dateFormat = "MMM yyyy"
                    return " back to \(f.string(from: first))"
                }()

                importStatus = added == 0
                    ? "Already up to date — all \(summary.parsed) plays were in your log."
                    : "Added \(added) plays\(span)."
                if summary.unavailable > 0 {
                    importStatus? += " \(summary.unavailable) skipped (removed videos)."
                }
                NSLog("[PRISM_IMPORT] parsed=\(summary.parsed) added=\(added) "
                      + "unavailable=\(summary.unavailable) notMusic=\(summary.notMusic) "
                      + "earliest=\(summary.earliest.map(String.init(describing:)) ?? "-") "
                      + "total=\(history.plays.count)")
            } catch {
                importing = false
                importStatus = error.localizedDescription
            }
        }
    }

    /// Pulls plays Last.fm knows about that Prism does not.
    func syncScrobbles() {
        guard scrobbler.isConnected else { return }
        Task {
            let since = history.earliest ?? Date().addingTimeInterval(-365 * 24 * 3600)
            let found = await scrobbler.recentPlays(since: since)
            let added = history.merge(found)
            importStatus = added == 0
                ? "Nothing new on Last.fm."
                : "Added \(added) plays from Last.fm."
        }
    }

    /// Single funnel for everything that reacts to engine state. Called on each
    /// snapshot rather than scattered across views, so history and the system's
    /// Now Playing tile stay correct even when no view is watching.
    func onSnapshot(_ snap: EngineSnapshot) {
        history.observe(track: snap.track, time: snap.currentTime,
                        playing: snap.playback.isPlaying, duration: snap.duration)
        nowPlaying?.update(snap)
        transitions.tick(snap)
        if let track = snap.track, track.videoId != lastAnnounced, snap.playback.isPlaying {
            lastAnnounced = track.videoId
            Task { await scrobbler.nowPlaying(track) }
        }
        if lyricsMode || ambientLyricsWanted { loadLyrics(for: snap.track) }
        refreshNextPalette()
        prefetchNextLyrics()
        // Ready before For You is opened, so the page arrives filled.
        if home.isEmpty, snap.ready { loadHome() }
        #if canImport(AppKit)
        listenForTempo(snap)
        #endif
    }

    #if canImport(AppKit)
    // MARK: Tempo memory

    /// Seconds the tracker has spent locked on each tempo of the song
    /// playing. Counted across the whole song, not as an unbroken run: on
    /// trap the tracker flips between a tempo and its 3:2 (measured, 134.5
    /// and 89.7 on one song), and a streak that reset at every flip never
    /// kept anything.
    private var tempoVotes: [(period: Double, seconds: Double)] = []
    private var trackSeen: (id: String, at: Date)?
    private var lastVote = Date()

    /// Hears each song's tempo and beat for AutoMix, and keeps them.
    ///
    /// With AutoMix on, capture runs for the first 45 seconds of a song (to
    /// learn it for when it is next the incoming track) and the last 50 (so
    /// the outgoing song's beat is live when a blend starts). The recording
    /// indicator shows for those windows; capture already running for the rim
    /// or locked mode counts too.
    ///
    /// A tempo is kept once it has been heard for ten seconds in total, eight
    /// seconds or more after the song started — the tracker carries the old
    /// song's tempo for a few seconds after a change — and only while it is the
    /// one heard most. The beat's position is taken whenever the tracker is on
    /// that tempo.
    private func listenForTempo(_ snap: EngineSnapshot) {
        let t = snap.currentTime, d = snap.duration
        let want = transitions.autoMix && transitions.seconds > 0 && snap.playback.isPlaying
            // The end window opens well before the blend does, so the
            // outgoing beat is locked by the time a 30-second fade starts.
            && d > 60 && (t < 45 || d - t < max(50, transitions.seconds + 25))
        liveAudio.set("automix", want)
        if !ambient.equalizersHear { liveAudio.releaseAll(prefix: "equalizer ") }
        engine.needPreciseClock("tempo memory", liveAudio.running)

        let now = Date()
        let dt = min(now.timeIntervalSince(lastVote), 2)
        lastVote = now
        guard let id = snap.track?.videoId else { return }
        if trackSeen?.id != id { trackSeen = (id, now); tempoVotes = [] }
        let b = liveAudio.bands
        guard liveAudio.running, snap.playback.isPlaying, !transitions.fading,
              let seen = trackSeen, now.timeIntervalSince(seen.at) > 8,
              let period = b.tempo, let beatAt = b.beatAt
        else { return }

        if let i = tempoVotes.firstIndex(where: { abs(period / $0.period - 1) < 0.01 }) {
            tempoVotes[i].seconds += dt
            tempoVotes[i].period = tempoVotes[i].period * 0.9 + period * 0.1
        } else {
            tempoVotes.append((period, dt))
        }
        guard let top = tempoVotes.max(by: { $0.seconds < $1.seconds }),
              top.seconds >= 10, abs(period / top.period - 1) < 0.01 else { return }
        // Where that beat fell in the song's own time.
        var phase = engine.smoothTime(at: beatAt).truncatingRemainder(dividingBy: period)
        if phase < 0 { phase += period }
        // The bar and the drop, when the kick has said which beat is the one.
        var barPhase: Double?
        var dropAt: Double?
        if let down = b.downbeatAt {
            let bar = period * 4
            var p = engine.smoothTime(at: down).truncatingRemainder(dividingBy: bar)
            if p < 0 { p += bar }
            barPhase = p
            // Only this song's beats, and only the last 40 seconds — further
            // back, a seek would make the mapping to song time wrong.
            let since = max(seen.at.addingTimeInterval(1), now.addingTimeInterval(-40))
            let heard = b.recentBeats.filter { $0.at > since }
            if heard.count >= 24,
               let first = heard.firstIndex(where: {
                   let n = Int(($0.at.timeIntervalSince(down) / period).rounded())
                   return ((n % 4) + 4) % 4 == 0 }),
               let i = DropFinder.drop(energies: heard.map(\.energy), firstDownbeat: first) {
                dropAt = engine.smoothTime(at: heard[i].at)
            }
        }
        tempoMemory.remember(id, period: period, phase: phase, duration: snap.duration, direct: true,
                             barPhase: barPhase, dropAt: dropAt)
        // Also under the queue row's id: YouTube often plays another version
        // from the one the queue lists (measured, row oCveByMXd_0 played as
        // sMrruvN56HA, and an "Instrumental" row played as the vocal), and a
        // mix loads the incoming track by the row. The recording's length goes
        // with it, so a mix can tell whether the beats carry over.
        if snap.queue.indices.contains(snap.queueIndex) {
            let row = snap.queue[snap.queueIndex]
            if row.videoId != id {
                tempoMemory.remember(row.videoId, period: period, phase: phase,
                                     duration: snap.duration, direct: false,
                                     barPhase: barPhase, dropAt: dropAt)
            }
        }
    }
    #endif

    // MARK: Locked-mode support

    /// Locked mode is showing lyrics. Lyrics otherwise load only while Now
    /// Playing's own lyrics toggle is on, which locked mode has nothing to do
    /// with — so it asks for them in its own right.
    var ambientLyricsWanted = false {
        didSet { if ambientLyricsWanted { ensureLyrics(); prefetchNextLyrics() } }
    }

    func ensureLyrics() { loadLyrics(for: engine.snapshot.track) }

    /// The queue entry that plays after this one, if there is one.
    var nextEntry: QueueEntry? {
        let s = engine.snapshot
        let i = s.queueIndex + 1
        guard i > 0, i < s.queue.count else { return nil }
        return s.queue[i]
    }

    /// The next track's colours, so a transition can hand the light from one
    /// song to the other. Cached per artwork like the current palette.
    private(set) var nextPalette: ArtPalette = .fallback
    private var nextPaletteFor: String?
    private var nextPaletteTask: Task<Void, Never>?

    /// Fetches the next song's lyrics while this one plays, so locked mode's
    /// lyrics are there the moment the song changes instead of loading then.
    private var lyricsPrefetchedFor: String?
    private func prefetchNextLyrics() {
        guard ambientLyricsWanted, let next = nextEntry,
              next.videoId != lyricsPrefetchedFor else { return }
        lyricsPrefetchedFor = next.videoId
        let track = Track(videoId: next.videoId, title: next.title, artist: next.artist,
                          durationText: next.durationText,
                          durationSeconds: next.durationText.flatMap(Self.seconds),
                          artworkURL: next.artworkURL)
        Task { await LyricsService.prefetch(track, engine: engine) }
    }

    /// "3:45" or "1:02:03" in seconds.
    private static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// The last few covers' colours, by image, readable without waiting.
    private var recentPalettes: [String: ArtPalette] = [:]
    private func remember(_ p: ArtPalette, for url: String?) {
        guard let key = ArtworkURL.key(url) else { return }
        if recentPalettes.count > 8, recentPalettes[key] == nil {
            recentPalettes.removeValue(forKey: recentPalettes.keys.first!)
        }
        recentPalettes[key] = p
    }

    private func refreshNextPalette() {
        let url = nextEntry?.artworkURL
        guard url != nextPaletteFor else { return }
        nextPaletteFor = url
        nextPaletteTask?.cancel()
        nextPaletteTask = Task {
            let found = await ArtworkPalette.palette(for: url)
            guard !Task.isCancelled else { return }
            remember(found, for: url)
            nextPalette = found
        }
    }

    // MARK: Lyrics

    func toggleLyrics() {
        lyricsMode.toggle()
        if lyricsMode {
            loadLyrics(for: engine.snapshot.track)
        } else {
            flash("Cover art")
        }
    }

    private func loadLyrics(for track: Track?) {
        guard let track else { lyrics = nil; lyricsFor = nil; return }
        guard lyricsFor != track.videoId else { return }
        lyricsFor = track.videoId
        lyrics = nil
        lyricsLoading = true
        lyricsTask?.cancel()
        lyricsTask = Task {
            let found = await LyricsService.lyrics(for: track, engine: engine)
            guard !Task.isCancelled, lyricsFor == track.videoId else { return }
            lyrics = found
            lyricsLoading = false
            if found.isEmpty { flash("No lyrics for “\(track.title)”") }
            else if !found.synced { flash("Lyrics from \(found.source) — not timed") }
        }
    }

    // MARK: For You

    /// YouTube Music's Home shelves for this account.
    var home: [HomeShelf] = []
    var homeLoading = false
    private var homeLoadedAt: Date?

    private var homeTriedAt: Date?

    func loadHome(force: Bool = false) {
        guard engine.snapshot.ready, !homeLoading else { return }
        if !force, let at = homeLoadedAt, Date().timeIntervalSince(at) < 600, !home.isEmpty { return }
        // A failed load is retried, but not on every snapshot.
        if !force, home.isEmpty, let tried = homeTriedAt, Date().timeIntervalSince(tried) < 60 { return }
        homeLoading = true
        homeTriedAt = Date()
        Task {
            defer { homeLoading = false }
            do {
                let shelves = try await engine.home()
                withAnimation(.smooth(duration: 0.3)) { home = shelves }
                homeLoadedAt = Date()
                evalLog("home.log", shelves.map { "\($0.title): \($0.items.count)\($0.isSongs ? " songs" : "")" }
                    .joined(separator: " · "))
            } catch {
                evalLog("home.log", "failed: \(error.localizedDescription)")
            }
        }
    }

    /// One line to `~/.prism-eval/<file>` under PRISM_EVAL.
    private func evalLog(_ file: String, _ line: String) {
        guard ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1" else { return }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".prism-eval/\(file)")
        let text = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: false))) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Whatever a Home card does: play a song, open a page, or start a mix.
    func play(_ item: HomeItem) {
        switch item.kind {
        case .song, .video:
            if let id = item.videoId { engine.play(videoId: id) }
        case .album, .playlist, .artist:
            if let shelf = item.asShelf { open(shelf) }
            else if let pid = item.playlistId { engine.playPlaylist(pid) }
        case .mix:
            if let pid = item.playlistId {
                engine.playPlaylist(pid)
                flash("Playing \(item.title)")
            } else if let shelf = item.asShelf { open(shelf) }
        }
    }

    var suggestions: [Track] = []
    var suggestionsLoading = false
    var suggestionSeed = ""
    private var suggestionsTask: Task<Void, Never>?

    /// Suggestions are a search against an artist you actually listen to,
    /// minus anything already in the log. YouTube exposes no recommendation
    /// endpoint we can call directly, and a home-feed scrape returns the same
    /// generic shelves for everyone, so this stays tied to your own history.
    func loadSuggestions(force: Bool = false) {
        guard force || (suggestions.isEmpty && !suggestionsLoading) else { return }
        let seeds = history.suggestionSeeds()
        guard let seed = seeds.randomElement() else { return }
        suggestionSeed = seed
        suggestionsLoading = true
        suggestionsTask?.cancel()
        suggestionsTask = Task {
            defer { suggestionsLoading = false }
            guard let results = try? await engine.search(seed) else { return }
            let heard = Set(history.plays.map(\.videoId))
            suggestions = results.songs.filter { !heard.contains($0.videoId) }
            if suggestions.isEmpty { suggestions = Array(results.songs.prefix(6)) }
        }
    }

    // MARK: Audio output

    #if canImport(AppKit)
    func selectOutput(_ device: OutputDevice) {
        if audio.select(device) { flash("Playing through \(device.name)") }
        else { flash("Couldn't switch to \(device.name).") }
    }
    #endif

    // Search
    var searchText = ""
    var searchResults: SearchResults?
    var searching = false
    /// Which filter chip is selected. Changing it re-runs the search rather
    /// than filtering what is already on screen, because the unfiltered
    /// response does not contain albums or artists at all.
    var searchScope: SearchScope = .all {
        didSet { if oldValue != searchScope { runSearch(immediately: true) } }
    }

    // Library
    var library: [LibrarySection] = []
    var libraryLoading = false
    var libraryLoaded = false

    // Opened playlist / album
    var detail: PlaylistDetail?
    var detailLoading = false

    var status: String?

    // Compact Now Playing
    var compact = false
    var palette: ArtPalette = .fallback
    var controlsVisible = true

    /// Whether the main window is on screen. False when it is buried behind
    /// another app or miniaturised, which is when the equalizer should stop
    /// animating — see WindowVisibility.
    var windowVisible = true

    private var searchTask: Task<Void, Never>?
    private var paletteTask: Task<Void, Never>?
    private var hideControlsTask: Task<Void, Never>?

    /// Shows the music video instead of the cover art, and lets it act as the
    /// app's background.
    var videoMode = false

    /// The webview's frame while the music video is on screen.
    var videoPlacement: VideoPlacement?
    /// Window bounds, reported by the root view; the placement maths needs them.
    var windowSize: CGSize = .zero
    private var videoFillTask: Task<Void, Never>?
    private var videoSwitchTask: Task<Void, Never>?

    /// Switches a paired track between its song and its music video.
    ///
    /// Switching to the video also turns video mode on, because the alternative
    /// is playing a music video behind a static cover — which is what asking
    /// for the video plainly does not mean. Switching back turns it off.
    ///
    /// The page needs a moment to load the other side before the fill can be
    /// measured, and `syncVideoMode` would otherwise see the old ATV type and
    /// pull us straight back out, so the mode is set after the switch lands.
    func setAVMode(video: Bool) {
        guard engine.snapshot.hasCounterpart else { return }
        engine.setAVMode(video: video)
        flash(video ? "Switching to the music video" : "Switching to the song")

        videoSwitchTask?.cancel()
        videoSwitchTask = Task {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                guard engine.snapshot.hasVideo == video else { continue }
                if video {
                    guard !videoMode else { return }
                    toggleVideoMode()
                } else if videoMode {
                    toggleVideoMode()
                }
                return
            }
        }
    }

    func toggleVideoMode() {
        videoMode.toggle()
        engine.setVideoMode(videoMode)
        withAnimation(.easeInOut(duration: 0.4)) { }
        flash(videoMode ? "Showing music video" : "Showing cover art")

        guard videoMode else {
            clearVideoFill()
            return
        }
        measureVideoFill()
    }

    private func clearVideoFill() {
        videoFillTask?.cancel()
        videoPlacement = nil
    }

    /// Places the webview so the video covers the window, by measuring what it
    /// actually did rather than predicting it.
    ///
    /// Two separate traps live here, and both were hit.
    ///
    /// The first: measuring *while a fill is applied* is a runaway. A taller
    /// webview means a taller viewport, which pushes the video further down the
    /// page, which reads as a bigger inset, which grows the webview again. Live
    /// it climbed `top` 817 → 1420 and `innerHeight` 2728 → 3934 in six steps —
    /// the picture visibly sliding downwards until the retry cap stopped it.
    /// Damping did not help, because nothing was oscillating around a fixed
    /// point; every reading was genuinely further out than the last. So the
    /// first measurement is always taken with no placement at all.
    ///
    /// The second: one measurement is not enough either. YouTube re-centres the
    /// video whenever the webview resizes, so a placement computed from the
    /// natural layout lands off — the picture stops short of the sidebar and the
    /// top. Hence the correction pass below: apply, measure where the video
    /// really ended up, and solve for the size and offset that put it over the
    /// window. That converges in a step or two and is capped.
    func measureVideoFill() {
        videoFillTask?.cancel()
        videoPlacement = nil
        videoFillTask = Task {
            guard let natural = await settledRect() else { return }
            guard videoMode, !Task.isCancelled else { return }

            let winW = windowSize.width, winH = windowSize.height
            guard winW > 1, winH > 1 else { return }

            // Opening bid: treat the page's insets as fixed and grow past the
            // window so a 16:9 picture still covers a non-16:9 window.
            let left = natural.x, top = natural.y
            let right = max(natural.vw - (natural.x + natural.w), 0)
            let bottom = max(natural.vh - (natural.y + natural.h), 0)
            let coverW = max(winW, winH * 16 / 9)
            let coverH = max(winH, winW * 9 / 16)
            var place = VideoPlacement(width: coverW + left + right,
                                       height: coverH + top + bottom,
                                       dx: -left - (coverW - winW) / 2,
                                       dy: -top - (coverH - winH) / 2)
            withAnimation(.easeInOut(duration: 0.3)) { videoPlacement = place }

            // Correction passes. Each one reads where the picture actually
            // landed and solves for the placement that centres and covers.
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(700))
                guard videoMode, !Task.isCancelled else { return }
                guard let r = engine.snapshot.videoRect, r.w > 40, r.h > 40,
                      r.vw > 1, r.vh > 1 else { continue }

                let sx = place.width / r.vw, sy = place.height / r.vh
                let shownW = r.w * sx, shownH = r.h * sy
                let centreX = place.dx + (r.x + r.w / 2) * sx
                let centreY = place.dy + (r.y + r.h / 2) * sy

                // 1.5% over so rounding never leaves a hairline of black.
                let grow = max(winW / shownW, winH / shownH, 1) * 1.015
                let centred = abs(centreX - winW / 2) < 2 && abs(centreY - winH / 2) < 2
                if grow <= 1.02, centred { return }

                place = VideoPlacement(
                    width: place.width * grow,
                    height: place.height * grow,
                    dx: winW / 2 - (r.x + r.w / 2) * sx * grow,
                    dy: winH / 2 - (r.y + r.h / 2) * sy * grow)
                withAnimation(.easeInOut(duration: 0.25)) { videoPlacement = place }
            }
        }
    }

    /// Waits for two agreeing readings of the *unplaced* page, which means the
    /// player page has finished opening rather than that a loop has converged.
    private func settledRect() async -> VideoRect? {
        var previous: VideoRect?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, videoMode else { return nil }
            guard let r = engine.snapshot.videoRect, r.w > 40, r.h > 40 else { continue }
            if let p = previous,
               abs(p.x - r.x) < 6, abs(p.y - r.y) < 6,
               abs(p.w - r.w) < 6, abs(p.h - r.h) < 6 {
                return r
            }
            previous = r
        }
        return nil
    }

    /// Songs with no picture (ATV) have nothing to show, so drop out of video
    /// mode rather than leaving a black screen behind the glass.
    func syncVideoMode(hasVideo: Bool) {
        guard videoMode, !hasVideo else { return }
        videoMode = false
        engine.setVideoMode(false)
        // The webview is still sized and offset to cover the window at this
        // point. Leaving that behind parks an enlarged, displaced page under
        // the glass for the rest of the session.
        clearVideoFill()
    }

    func toggleCompact() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            compact.toggle()
        }
        if compact { nudgeControls() } else { controlsVisible = true }
        // Compact changes the window's layout, so a fill measured against the
        // old one no longer lines up. Drop it and measure again.
        if videoMode {
            engine.nudgeVideoLayout()
            measureVideoFill()
        }
    }

    /// Any mouse movement re-reveals the transport, which then hides itself.
    func nudgeControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        }
        hideControlsTask?.cancel()
        guard compact else { return }
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled, compact else { return }
            withAnimation(.easeInOut(duration: 0.5)) { controlsVisible = false }
        }
    }

    func refreshPalette(for artworkURL: String?) {
        // The song that just started is the one a transition was already
        // blending towards, so its colours are known. Taking them immediately
        // stops the rim flashing back to the *outgoing* song's colours for the
        // ~0.7s the fetch-and-animate would otherwise take.
        // Looked up by image, not URL: the queue's thumbnail and the player's
        // art are the same cover at different sizes, and comparing the URLs
        // never matched — the rim flashed back to the old song at every swap.
        // A memo rather than just "was it the next one": YouTube sometimes
        // moves the queue on before it reports the new song, by which time
        // `nextPalette` already belongs to the song after.
        if let key = ArtworkURL.key(artworkURL), let known = recentPalettes[key] {
            paletteTask?.cancel()
            palette = known
            return
        }
        paletteTask?.cancel()
        paletteTask = Task {
            let next = await ArtworkPalette.palette(for: artworkURL)
            guard !Task.isCancelled else { return }
            remember(next, for: artworkURL)
            withAnimation(.easeInOut(duration: 0.7)) { palette = next }
        }
    }

    func runSearch(immediately: Bool = false) {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !text.isEmpty else { searchResults = nil; searching = false; return }
        searching = true
        searchTask = Task {
            // Debounce so typing does not fire a request per keystroke. A chip
            // is a deliberate click, so it skips the wait.
            if !immediately { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            do {
                var results = try await engine.search(text, scope: searchScope)
                guard !Task.isCancelled else { return }
                // Only re-rank the unfiltered search. Picking a chip is asking
                // for YouTube's ranking of that one kind, and shuffling it
                // afterwards would be answering a different question.
                if searchScope == .all { results.songs = rank(results.songs, for: text) }
                searchResults = results
            } catch {
                status = "Search failed: \(error.localizedDescription)"
            }
            searching = false
        }
    }

    /// Re-orders search results towards what this listener actually plays.
    ///
    /// The bridge has already put YouTube's own shelves in a sane order, which
    /// stops user-uploaded reposts outranking real releases. This adds the part
    /// only the app knows: an artist you have played fifty times is almost
    /// certainly the one you meant, so searching "Power" should not offer six
    /// strangers before the Kanye West track you have on repeat.
    ///
    /// Deliberately a *sort*, not a filter — nothing is hidden, and an exact
    /// title match still beats familiarity, so a genuinely new song is still
    /// reachable by name.
    private func rank(_ songs: [Track], for query: String) -> [Track] {
        let needle = query.lowercased()

        // How much of your listening each artist accounts for, 0…1.
        var byArtist: [String: Int] = [:]
        for play in history.plays where !play.artist.isEmpty {
            byArtist[play.artist.lowercased(), default: 0] += 1
        }
        let busiest = max(byArtist.values.max() ?? 0, 1)

        func score(_ track: Track, position: Int) -> Double {
            var score = 0.0

            // YouTube's own ordering is the starting point, not a tiebreak:
            // it is right far more often than any heuristic here.
            score += max(0, 60 - Double(position)) * 0.5

            let title = track.title.lowercased()
            if title == needle { score += 40 }
            else if title.hasPrefix(needle) { score += 22 }
            else if title.contains(needle) { score += 10 }

            // Familiarity, capped so a favourite artist cannot bury an exact
            // title match for someone new.
            let plays = byArtist[track.artist.lowercased()] ?? 0
            if plays > 0 { score += 12 + 18 * (Double(plays) / Double(busiest)) }

            // A reupload usually announces itself by carrying the artist's name
            // in the title, since the uploader is not the artist.
            if title.contains(" - ") && !track.artist.isEmpty
                && title.contains(track.artist.lowercased()) == false
                && title.split(separator: "-").count > 1 {
                score -= 6
            }
            if (track.shelf ?? "").lowercased().contains("video") { score -= 12 }

            return score
        }

        return songs.enumerated()
            .map { (index, track) in (track, score(track, position: index)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func loadLibraryIfNeeded(force: Bool = false) {
        guard force || (!libraryLoaded && !libraryLoading) else { return }
        libraryLoading = true
        Task {
            do {
                // Ask again if the first answer looks like it was asked too
                // early.
                //
                // The library is fetched the moment the tab appears, which can
                // be before the page has finished establishing its signed-in
                // session. InnerTube answers anyway, and answers *badly*: on a
                // cold launch it came back with no sections at all ("Nothing in
                // your library yet"), and on another with the right playlists
                // and every thumbnail missing — real titles, real track counts,
                // no artwork. Tapping Retry fixed both, which is the tell.
                //
                // So the retry is built in rather than left to the user. Empty
                // sections and artwork-less items are both treated as "too
                // early" and asked again once, a second later.
                var sections = try await engine.loadLibrary()
                if Self.looksUnauthenticated(sections) {
                    try? await Task.sleep(for: .seconds(1))
                    let second = try await engine.loadLibrary()
                    if !Self.looksUnauthenticated(second) || sections.isEmpty {
                        sections = second
                    }
                }
                library = sections
                libraryLoaded = true
                if library.isEmpty {
                    status = engine.snapshot.signedIn
                        ? "Your library came back empty."
                        : "Sign in to see your library."
                }
            } catch {
                status = "Library failed: \(error.localizedDescription)"
            }
            libraryLoading = false
        }
    }

    /// Whether a library response has the shape of one fetched before the
    /// session was ready: nothing at all, or items with no artwork on any of
    /// them. A real library has cover art — YouTube generates a mosaic even
    /// for playlists the user never gave one.
    private static func looksUnauthenticated(_ sections: [LibrarySection]) -> Bool {
        if sections.isEmpty { return true }
        let items = sections.flatMap(\.items)
        guard !items.isEmpty else { return true }
        return items.allSatisfy { ($0.artworkURL ?? "").isEmpty }
    }

    func open(_ shelf: Shelf) {
        // Remember where this was opened from, so Back returns there. It used
        // to always go to Library, which stranded anyone who arrived from a
        // search — and now that an artist page links on to albums, going back
        // has to unwind one step at a time rather than jumping to the root.
        if case .detail = route {} else { detailOrigin = route }
        if case .detail(let id, let t) = route { detailStack.append((id, t)) }
        route = .detail(browseId: shelf.browseId, title: shelf.title)
        detail = nil
        detailLoading = true
        Task {
            do { detail = try await engine.loadPlaylist(shelf.browseId) }
            catch { status = "Could not open \(shelf.title): \(error.localizedDescription)" }
            detailLoading = false
        }
    }

    /// Reports what the engine actually did, not what we hoped it would do.
    func enqueue(_ track: Track, atEnd: Bool) {
        // Immediate feedback, replaced by the real outcome ~2s later. Also the
        // cleanest way to tell "toast is broken" apart from "enqueue hung".
        status = atEnd ? "Adding to queue…" : "Queueing next…"
        Task {
            do {
                let r = try await engine.enqueue(videoId: track.videoId, atEnd: atEnd)
                if r.ok {
                    flash(atEnd ? "Added to queue: \(track.title)"
                                : "Playing next: \(track.title)")
                } else if r.hijackedPlayback {
                    flash("YouTube started “\(track.title)” instead of queuing it.")
                } else if !engine.snapshot.signedIn {
                    flash("Sign in to add songs to the queue.")
                } else {
                    flash("Couldn't queue “\(track.title)”.")
                }
            } catch {
                flash("Queue error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Queue edits
    //
    // Each of these reports what the queue actually did rather than assuming.
    // Every one of them used to be a no-op: the bridge passed row indices to
    // YouTube methods that match on item objects, so nothing was ever found.

    func moveInQueue(from: Int, to: Int) {
        let queue = engine.snapshot.queue
        guard from >= 0, from < queue.count, to >= 0, to < queue.count, from != to else { return }
        let title = queue[from].title
        engine.moveInQueue(from: from, to: to)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            let now = engine.snapshot.queue
            if to < now.count, now[to].videoId == queue[from].videoId {
                flash("Moved \(title) to #\(to + 1)")
            } else {
                flash("Couldn't move \(title).")
            }
        }
    }

    func removeFromQueue(_ entry: QueueEntry) {
        let before = engine.snapshot.queue.count
        engine.removeFromQueue(at: entry.index)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            flash(engine.snapshot.queue.count < before
                  ? "Removed \(entry.title)"
                  : "Couldn't remove \(entry.title).")
        }
    }

    func clearQueue() {
        let before = engine.snapshot.queue.count
        guard before > 1 else { return }
        engine.clearQueue()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            let after = engine.snapshot.queue.count
            flash(after < before ? "Cleared \(before - after) from the queue"
                                 : "Couldn't clear the queue.")
        }
    }

    func undoQueueEdit() {
        guard let label = engine.snapshot.undoLabel else { return }
        engine.undoQueue()
        flash("Undid \(label)")
    }

    // MARK: Ambient

    /// Seconds per beat for the track playing, or nil when nobody knows.
    ///
    /// The tempo comes from the same lookup AutoMix uses, so the pulse costs
    /// one cache read and no new analysis. Deezer answers `bpm: 0` for a great
    /// many tracks, which is why this is so often nil and the light falls back
    /// to breathing rather than inventing a tempo.
    var beatPeriod: Double? {
        ambient.motion == .beat ? trackTempo : nil
    }

    /// Where the lyrics are: the playback clock less the chosen delay.
    func lyricsTime(at date: Date = Date()) -> Double {
        engine.smoothTime(at: date) - ambient.lyricsDelay
    }

    /// The looked-up tempo whatever the motion setting — the flowing line's
    /// pace when the audio itself is not being heard.
    var trackTempo: Double? {
        guard let id = engine.snapshot.track?.videoId,
              let bpm = transitions.analysis.cached(id)?.bpm, bpm > 30
        else { return nil }
        return 60 / bpm
    }

    /// Asks for the tempo of whatever is playing, so beat motion and the
    /// flowing line have something to work with without waiting for a
    /// crossfade to arm.
    func prefetchTempoIfNeeded() {
        guard ambient.motion == .beat || (ambient.rimGlow && ambient.flow),
              let t = engine.snapshot.track else { return }
        transitions.analysis.prefetch(videoId: t.videoId, title: t.title,
                                      artist: t.artist,
                                      duration: engine.snapshot.duration)
    }

    #if canImport(AppKit)
    func toggleAmbient() { ambientPanel.toggle() }
    func dismissAmbient() { ambientPanel.dismiss() }

    /// Brings the ambient surface up after a spell of no input.
    ///
    /// `secondsSinceLastEventType` is the same idle clock the system screen
    /// saver reads, so this agrees with what the Mac itself considers idle
    /// rather than inventing a second definition. Only ever while something is
    /// playing: a silent Mac going ambient on its own would be a screen saver
    /// nobody asked for.
    private func startIdleWatch() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                guard !ambient.presenting,
                      engine.snapshot.playback.isPlaying,
                      ambient.idleSeconds > 0 else { continue }
                let idle = CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState, eventType: .init(rawValue: ~0)!)
                if idle >= ambient.idleSeconds { ambientPanel.present() }
            }
        }
    }
    /// When the volume HUD in locked mode was last touched, and what it shows.
    /// Held locally because snapshots lag a scroll gesture by up to a second,
    /// and reading the snapshot mid-gesture would make the level jump back.
    private(set) var volumeHUDAt: Date?
    private(set) var volumeHUDLevel: Double = 100

    func nudgeVolume(by delta: Double) {
        let fresh = volumeHUDAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false
        let base = fresh ? volumeHUDLevel : engine.snapshot.volume
        volumeHUDLevel = min(max(base + delta, 0), 100)
        engine.setVolume(volumeHUDLevel)
        volumeHUDAt = Date()
    }
    #else
    func toggleAmbient() {}
    func dismissAmbient() {}
    #endif

    func shuffleQueue() {
        engine.shuffleQueue()
        flash("Shuffled the queue")
    }

    func download(_ track: Track) {
        download(videoId: track.videoId, title: track.title, artist: track.artist,
                 artworkURL: track.artworkURL)
    }

    func download(videoId: String, title: String, artist: String = "", artworkURL: String? = nil) {
        status = "Downloading \(title)…"
        downloads.note(DownloadRecord(videoId: videoId, title: title, artist: artist,
                                      artworkURL: artworkURL, requestedAt: Date(),
                                      status: .requested))
        Task {
            do {
                let r = try await engine.download(videoId: videoId)
                // Deliberately not "Downloaded". The endpoint is accepted, but
                // YouTube returns no confirmation and no Downloads shelf shows
                // up afterwards, so claiming success would be a guess.
                if r.supported && r.ok {
                    flash("Download requested: \(title)")
                } else {
                    downloads.set(videoId, r.supported ? .failed : .unavailable,
                                  note: r.reason.isEmpty ? nil : r.reason)
                    flash(r.reason.isEmpty ? "Download failed." : r.reason)
                }
            } catch {
                downloads.set(videoId, .failed, note: error.localizedDescription)
                flash("Download error: \(error.localizedDescription)")
            }
        }
    }

    /// Cancels a download on YouTube and marks it so here.
    func removeDownload(_ record: DownloadRecord) {
        Task {
            let r = try? await engine.download(videoId: record.videoId, remove: true)
            if r?.supported == true && r?.ok == true {
                downloads.set(record.videoId, .removed)
                flash("Cancelled the download of \(record.title)")
            } else {
                flash(r?.reason.isEmpty == false ? r!.reason : "Couldn't cancel that download.")
            }
        }
    }

    func playAll(_ tracks: [Track], title: String) {
        guard let first = tracks.first else { return }
        // One playlist load beats one /next round-trip per track.
        if let pid = detail?.playlistId, !pid.isEmpty {
            engine.playPlaylist(pid)
            flash("Playing \(title)")
            return
        }
        Task {
            engine.play(videoId: first.videoId)
            flash("Playing \(title)")
            try? await Task.sleep(for: .seconds(2.5))
            for t in tracks.dropFirst() {
                _ = try? await engine.enqueue(videoId: t.videoId, atEnd: true)
            }
        }
    }

    func flash(_ message: String) {
        status = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if status == message { status = nil }
        }
    }
}
