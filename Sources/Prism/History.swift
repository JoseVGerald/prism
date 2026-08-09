import Foundation
import Observation

/// Where a play came from, and therefore how much its numbers can be trusted.
enum PlaySource: String, Codable {
    /// Prism watched it happen and timed it against the player's own clock.
    case measured
    /// Read out of a Google Takeout export. The timestamp is exact; the
    /// duration is not, because Takeout records *that* you played something and
    /// never *how long for*.
    case imported
    /// Pulled back from Last.fm, so it happened somewhere other than this Mac.
    /// Same caveat as an import: a scrobble carries no duration either.
    case scrobbled
}

/// One finished listen.
struct Play: Codable, Identifiable, Hashable {
    var videoId: String
    var title: String
    var artist: String
    var artworkURL: String?
    /// When the track started.
    var at: Date
    /// Wall-clock seconds actually spent listening, not the track's length.
    ///
    /// For anything other than `.measured` this is an estimate — see
    /// `PlaySource`. Aggregations that add it up must say so.
    var seconds: Double

    /// Optional so that history written before provenance existed still decodes;
    /// those entries were all measured, which is what `nil` means here.
    var source: PlaySource?

    /// True when `seconds` is a stand-in rather than something anyone observed.
    var isEstimated: Bool { source == .imported || source == .scrobbled }

    /// Typical track length, used as the stand-in duration for a play nobody
    /// timed. Deliberately one obvious constant rather than a per-track guess
    /// dressed up as data. Lives here rather than on `History` so the importer
    /// can reach it from off the main actor.
    static let assumedLength: Double = 195

    var id: String { "\(videoId)-\(at.timeIntervalSince1970)" }
}

/// Prism's own listening log.
///
/// The log starts the first time you press play and fills in from there. It
/// never leaves the machine.
///
/// **Why nothing is imported from YouTube.** An earlier comment here claimed
/// `FEmusic_history` came back empty. That is no longer true and was worth
/// re-measuring: it returns 2.3 MB and 200 tracks across four shelves. It is
/// still useless *for statistics*, for three separate reasons:
///
/// * **Deduplicated.** 200 entries, 200 distinct video IDs. A song played
///   twenty times appears once, so there are no play counts to import.
/// * **No timestamps.** Entries are bucketed into "Today", "Yesterday",
///   "This week" and "Last week" and carry no time field, so hours listened,
///   time-of-day and streaks cannot be reconstructed.
/// * **No pagination.** There is not a single continuation token in the
///   response — the feed stops at roughly two weeks with no way further back.
///
/// Merging it into the counters would not enrich them, it would corrupt them:
/// every track worth one play, and no duration to total. What the feed *is*
/// good for is "what have I been listening to lately", which is the For You
/// page's job, not the dashboard's.
@MainActor
@Observable
final class History {

    private(set) var plays: [Play] = []

    /// Kept small enough to load and scan synchronously without anyone noticing.
    private let cap = 20_000

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prism", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }()

    // A play is only recorded once it has actually been listened to, so skipping
    // through a queue does not pollute the stats.
    private var currentId: String?
    private var currentTrack: Track?
    private var startedAt: Date?
    private var heard: Double = 0
    private var lastTick: Double = 0
    /// Length of the track being listened to, kept because a scrobble has to
    /// know it to apply Last.fm's "half the track or four minutes" rule.
    private var currentLength: Double = 0

    /// Called when a play is committed to the log. The scrobbler hangs off this
    /// rather than the snapshot, so it fires exactly once per play and only for
    /// listens long enough to count.
    @ObservationIgnored var onPlay: ((Play, Double) -> Void)?

    init() { load() }

    // MARK: Recording

    /// Called on every engine snapshot. Detects track changes and accumulates
    /// listening time from the player's own clock, so pausing does not count.
    func observe(track: Track?, time: Double, playing: Bool, duration: Double = 0) {
        guard let track else { flush(); return }

        if track.videoId != currentId {
            flush()
            currentId = track.videoId
            currentTrack = track
            startedAt = Date()
            heard = 0
            lastTick = time
            currentLength = duration
            return
        }
        // Keep the metadata fresh, do not just keep the first version of it.
        //
        // This was a real bug and a nasty one, because it corrupted the log
        // rather than the display. `getVideoData()` updates `video_id` a tick
        // or two *before* it updates `title` and `author`, so the snapshot that
        // first reports a new track still carries the previous track's name.
        // Capturing `currentTrack` only at the transition therefore filed every
        // play under the title of the song before it — verified end to end:
        //
        //     dQw4w9WgXcQ (Never Gonna Give You Up) -> "Unknown", ""
        //     3JZ_D3ELwOQ (Flexin' On Ya)           -> "Never Gonna Give You Up"
        //     9bZkp7q19f0 (Gangnam Style)           -> "Flexin' On Ya (2014)"
        //
        // Correct videoId every time, wrong name every time, so the mistake was
        // invisible in the player (which reads the live snapshot) and only
        // showed up in Listening, top artists and recently-played.
        //
        // The id is what identifies the play; the rest is allowed to arrive
        // late, so it is taken from the newest snapshot right up until flush.
        if track.videoId == currentId { currentTrack = track }

        // The duration arrives a tick or two after the track does.
        if duration > 0 { currentLength = duration }

        // Forward progress only: a seek backwards or a loop restart must not
        // subtract, and a seek forwards must not credit time nobody heard.
        let delta = time - lastTick
        if playing, delta > 0, delta < 2 { heard += delta }
        lastTick = time
    }

    /// Writes the in-flight track to the log if enough of it was heard.
    func flush() {
        let length = currentLength
        defer { currentId = nil; currentTrack = nil; startedAt = nil; heard = 0; currentLength = 0 }
        guard let t = currentTrack, let started = startedAt, heard >= 25 else { return }
        let play = Play(videoId: t.videoId, title: t.title, artist: t.artist,
                        artworkURL: t.artworkURL, at: started, seconds: heard,
                        source: .measured)
        plays.append(play)
        if plays.count > cap { plays.removeFirst(plays.count - cap) }
        save()
        onPlay?(play, length)
    }

    // MARK: Merging in plays from elsewhere

    /// Folds in plays from a Takeout export or from Last.fm.
    ///
    /// Merging is the whole difficulty here. An import overlaps whatever Prism
    /// already recorded — the export covers days this Mac was running, and a
    /// scrobble pull covers plays Prism itself scrobbled — so the same listen
    /// arrives twice from two directions. Anything within `window` of an
    /// existing play of the same track is treated as that play, and the
    /// *measured* copy always wins, because it is the one with a real duration.
    ///
    /// This also makes re-importing the same file harmless, which matters: you
    /// will re-export from Takeout to top up, and the overlap will be months.
    ///
    /// - Returns: how many were genuinely new.
    @discardableResult
    func merge(_ incoming: [Play], window: TimeInterval = 90) -> Int {
        guard !incoming.isEmpty else { return 0 }

        // Bucket existing plays by track and by minute so the check stays close
        // to linear. A naive pairwise scan is 20k × 100k on a real import.
        var index: [String: [Int]] = [:]
        for (i, p) in plays.enumerated() {
            index[p.videoId, default: []].append(i)
        }

        var added: [Play] = []
        for candidate in incoming {
            let siblings = index[candidate.videoId] ?? []
            let duplicate = siblings.contains { i in
                abs(plays[i].at.timeIntervalSince(candidate.at)) < window
            }
            if duplicate { continue }
            // Also guard against duplicates inside the incoming batch itself.
            if added.contains(where: {
                $0.videoId == candidate.videoId
                && abs($0.at.timeIntervalSince(candidate.at)) < window
            }) { continue }
            added.append(candidate)
        }

        guard !added.isEmpty else { return 0 }
        plays.append(contentsOf: added)
        plays.sort { $0.at < $1.at }
        if plays.count > cap { plays.removeFirst(plays.count - cap) }
        save()
        return added.count
    }

    /// Whether any play in a window has a stand-in duration, so the dashboard
    /// can mark its totals as approximate rather than quietly rounding a guess
    /// into a headline number.
    func hasEstimates(since: Date) -> Bool {
        plays(since: since).contains(where: \.isEstimated)
    }

    /// Oldest play on record, for showing how far the stats actually reach.
    var earliest: Date? { plays.min(by: { $0.at < $1.at })?.at }

    // MARK: Reading

    /// Most recent first, one entry per track.
    func recent(limit: Int = 40) -> [Play] {
        var seen = Set<String>()
        var out: [Play] = []
        for p in plays.reversed() {
            if seen.insert(p.videoId).inserted { out.append(p) }
            if out.count == limit { break }
        }
        return out
    }

    func plays(since: Date) -> [Play] { plays.filter { $0.at >= since } }

    /// Artists ranked by listening time in a window.
    func topArtists(since: Date, limit: Int = 8) -> [(name: String, seconds: Double, plays: Int)] {
        var totals: [String: (Double, Int)] = [:]
        for p in plays(since: since) where !p.artist.isEmpty {
            let cur = totals[p.artist] ?? (0, 0)
            totals[p.artist] = (cur.0 + p.seconds, cur.1 + 1)
        }
        return totals.map { (name: $0.key, seconds: $0.value.0, plays: $0.value.1) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(limit).map { $0 }
    }

    /// Tracks ranked by play count in a window.
    func topTracks(since: Date, limit: Int = 8) -> [(play: Play, count: Int)] {
        var counts: [String: (Play, Int)] = [:]
        for p in plays(since: since) {
            let cur = counts[p.videoId]
            counts[p.videoId] = (cur?.0 ?? p, (cur?.1 ?? 0) + 1)
        }
        return counts.values.map { (play: $0.0, count: $0.1) }
            .sorted { $0.count > $1.count }
            .prefix(limit).map { $0 }
    }

    func seconds(since: Date) -> Double { plays(since: since).reduce(0) { $0 + $1.seconds } }

    /// Consecutive days up to today with at least one play.
    var streak: Int {
        let cal = Calendar.current
        let days = Set(plays.map { cal.startOfDay(for: $0.at) })
        guard !days.isEmpty else { return 0 }
        var day = cal.startOfDay(for: Date())
        // Yesterday still counts as a live streak until today's first play.
        if !days.contains(day) {
            guard let back = cal.date(byAdding: .day, value: -1, to: day), days.contains(back)
            else { return 0 }
            day = back
        }
        var n = 0
        while days.contains(day) {
            n += 1
            guard let back = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = back
        }
        return n
    }

    /// Listening seconds per day across a window, oldest first.
    func daily(days: Int) -> [(day: Date, seconds: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var buckets: [Date: Double] = [:]
        for p in plays {
            let d = cal.startOfDay(for: p.at)
            buckets[d, default: 0] += p.seconds
        }
        return (0..<days).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day: d, seconds: buckets[d] ?? 0)
        }
    }

    /// Artists you have played before, most-listened first, for seeding
    /// suggestions. Excludes anything played in the last few hours so the
    /// suggestions are not just what is already on.
    func suggestionSeeds(limit: Int = 6) -> [String] {
        let recentCutoff = Date().addingTimeInterval(-3 * 3600)
        let justPlayed = Set(plays(since: recentCutoff).map(\.artist))
        return topArtists(since: .distantPast, limit: 40)
            .map(\.name)
            .filter { !justPlayed.contains($0) }
            .prefix(limit).map { $0 }
    }

    var isEmpty: Bool { plays.isEmpty }

    // MARK: Storage

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Play].self, from: data) else { return }
        plays = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(plays) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
