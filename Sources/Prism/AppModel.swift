import SwiftUI
import Observation
#if canImport(AppKit)
import CoreGraphics
#endif

enum Route: Hashable {
    case forYou
    case nowPlaying
    case search
    case library
    case dashboard
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
        quality = QualitySettings(engine: engine)
        nowPlaying = NowPlaying(engine: engine)
        engine.onDocumentReady = { [quality] in quality.applyToEngine() }
        #if canImport(AppKit)
        notch = NotchController(model: self)
        notch.open()
        probe.startIfEnabled()
        ambientPanel = AmbientPanelController(model: self)
        startIdleWatch()
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
        if lyricsMode { loadLyrics(for: snap.track) }
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
        paletteTask?.cancel()
        paletteTask = Task {
            let next = await ArtworkPalette.palette(for: artworkURL)
            guard !Task.isCancelled else { return }
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
        guard ambient.motion == .beat,
              let id = engine.snapshot.track?.videoId,
              let bpm = transitions.analysis.cached(id)?.bpm, bpm > 30
        else { return nil }
        return 60 / bpm
    }

    /// Asks for the tempo of whatever is playing, so beat motion has something
    /// to work with without waiting for a crossfade to arm.
    func prefetchTempoIfNeeded() {
        guard ambient.motion == .beat, let t = engine.snapshot.track else { return }
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
    #else
    func toggleAmbient() {}
    func dismissAmbient() {}
    #endif

    func shuffleQueue() {
        engine.shuffleQueue()
        flash("Shuffled the queue")
    }

    func download(_ track: Track) { download(videoId: track.videoId, title: track.title) }

    func download(videoId: String, title: String) {
        status = "Downloading \(title)…"
        Task {
            do {
                let r = try await engine.download(videoId: videoId)
                // Deliberately not "Downloaded". The endpoint is accepted, but
                // YouTube returns no confirmation and no Downloads shelf shows
                // up afterwards, so claiming success would be a guess.
                if r.supported && r.ok {
                    flash("Download requested: \(title)")
                } else {
                    flash(r.reason.isEmpty ? "Download failed." : r.reason)
                }
            } catch {
                flash("Download error: \(error.localizedDescription)")
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
