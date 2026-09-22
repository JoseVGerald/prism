import Foundation
// A module on macOS, compiled into the binary on iOS — see build-ios.sh.
#if canImport(AutoMixCore)
import AutoMixCore
#endif

struct LyricLine: Identifiable, Hashable {
    /// Seconds into the track. Nil for unsynced sheets.
    var at: Double?
    var text: String
    var id: Int
    /// Exact word starts from enhanced LRC, on the rare track that has them.
    var wordStarts: [Double]? = nil
}

struct Lyrics {
    var lines: [LyricLine]
    var synced: Bool
    var source: String

    var isEmpty: Bool { lines.isEmpty }

    /// The lines in the form the word-timing model takes. Empty when unsynced.
    var timed: [TimedLine] {
        guard synced else { return [] }
        return lines.compactMap { l in
            l.at.map { TimedLine(start: $0, text: l.text, wordStarts: l.wordStarts) }
        }
    }

    /// Index of the line that should be lit at `time`, if any.
    func index(at time: Double) -> Int? {
        guard synced else { return nil }
        var found: Int?
        for (i, l) in lines.enumerated() {
            guard let t = l.at else { continue }
            if t <= time + 0.25 { found = i } else { break }
        }
        return found
    }
}

/// Fetches lyrics, preferring the best-timed.
///
/// Three sources, asked at once:
/// - **LRCLIB**, a free public database of community-timed LRC files. Usually
///   timed per line; now and then per word (enhanced LRC).
/// - **YouTube Music's timed lyrics** — Musixmatch's, the same provider Spotify
///   uses, timed per line by people and checked. The web client only ever gets
///   plain text, but the Android app gets the same lyrics page with cue times
///   (measured: 59 timed lines, "Source: Musixmatch").
/// - **YouTube Music's plain text**, for tracks neither has timed.
///
/// Preference: LRCLIB when it has per-word times, else Musixmatch, else
/// LRCLIB's line times, else any plain text. Off-machine: the title, artist,
/// album and duration to LRCLIB; the video id to YouTube, which already has it.
@MainActor
enum LyricsService {

    private static var cache: [String: Lyrics] = [:]

    static func lyrics(for track: Track, engine: Engine) async -> Lyrics {
        if let hit = cache[track.videoId] { return hit }
        let found = await fetch(track, engine: engine)
        if !found.isEmpty { cache[track.videoId] = found }
        return found
    }

    /// Looks a coming track up ahead of time, so its lyrics are there the
    /// moment it starts. Works for any track: the YouTube lookups take the
    /// video id, not whatever the page is playing.
    static func prefetch(_ track: Track, engine: Engine) async {
        guard cache[track.videoId] == nil else { return }
        _ = await lyrics(for: track, engine: engine)
    }

    private static func fetch(_ track: Track, engine: Engine) async -> Lyrics {
        async let community = lrclib(track)
        async let page = try? engine.lyrics(videoId: track.videoId)
        let (lrc, yt) = await (community, page)

        if let lrc, lrc.synced, lrc.lines.contains(where: { $0.wordStarts != nil }) { return lrc }
        if let id = yt?.browseId, let timed = await youtubeTimed(browseId: id) { return timed }
        if let lrc, lrc.synced { return lrc }
        if let text = yt?.text, !text.isEmpty {
            return Lyrics(lines: split(text), synced: false, source: yt?.source ?? "YouTube Music")
        }
        return lrc ?? Lyrics(lines: [], synced: false, source: "")
    }

    // MARK: YouTube Music, timed

    /// The Android app's client identity. If YouTube retires this version the
    /// request fails and the other sources carry on.
    private static let androidClient: [String: Any] = [
        "clientName": "ANDROID_MUSIC", "clientVersion": "7.21.50",
        "androidSdkVersion": 30, "hl": "en", "gl": "US"
    ]

    private static func youtubeTimed(browseId: String) async -> Lyrics? {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false"),
              let body = try? JSONSerialization.data(withJSONObject: [
                "context": ["client": androidClient], "browseId": browseId])
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("com.google.android.apps.youtube.music/7.21.50 (Linux; U; Android 11) gzip",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data),
              let model = first("timedLyricsModel", in: json) as? [String: Any],
              let lyricsData = model["lyricsData"] as? [String: Any],
              let cues = lyricsData["timedLyricsData"] as? [[String: Any]]
        else { return nil }

        var lines: [LyricLine] = []
        for cue in cues {
            guard let text = cue["lyricLine"] as? String,
                  let range = cue["cueRange"] as? [String: Any],
                  let ms = (range["startTimeMilliseconds"] as? String).flatMap(Double.init)
                        ?? (range["startTimeMilliseconds"] as? Double)
            else { continue }
            lines.append(LyricLine(at: ms / 1000, text: text, id: lines.count))
        }
        guard !lines.isEmpty else { return nil }
        let source = (lyricsData["sourceMessage"] as? String)?
            .replacingOccurrences(of: "Source: ", with: "") ?? "YouTube Music"
        return Lyrics(lines: lines, synced: true, source: source)
    }

    /// The first value under `key` anywhere in a decoded JSON tree. The
    /// response nests it deep in renderer wrappers whose names change more
    /// often than the model itself does.
    private static func first(_ key: String, in node: Any) -> Any? {
        if let dict = node as? [String: Any] {
            if let hit = dict[key] { return hit }
            for value in dict.values { if let hit = first(key, in: value) { return hit } }
        } else if let list = node as? [Any] {
            for value in list { if let hit = first(key, in: value) { return hit } }
        }
        return nil
    }

    // MARK: LRCLIB

    private struct LRCResponse: Decodable {
        var trackName: String?
        var artistName: String?
        var syncedLyrics: String?
        var plainLyrics: String?
    }

    private static func lrclib(_ track: Track) async -> Lyrics? {
        // Featured-artist suffixes and "(Official Video)" style noise are the
        // usual reason a match fails, so the query is cleaned before asking.
        let title = clean(track.title)
        let artist = clean(track.artist)
        guard !title.isEmpty else { return nil }

        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: artist)
        ]
        if let d = track.durationSeconds, d > 0 {
            get.queryItems?.append(.init(name: "duration", value: String(Int(d.rounded()))))
        }

        if let r = await request(get.url), let l = parse(r) { return l }

        // Exact-match failed; the search endpoint is looser about punctuation
        // and featured artists.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [.init(name: "q", value: "\(artist) \(title)")]
        guard let url = search.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([LRCResponse].self, from: data)
        else { return nil }

        // Prefer a hit that is actually synced over the first hit.
        let best = list.first(where: { $0.syncedLyrics?.isEmpty == false }) ?? list.first
        return best.flatMap(parse)
    }

    private static func request(_ url: URL?) async -> LRCResponse? {
        guard let url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(LRCResponse.self, from: data)
    }

    private static func parse(_ r: LRCResponse) -> Lyrics? {
        if let lrc = r.syncedLyrics, !lrc.isEmpty {
            let lines = parseLRC(lrc)
            if !lines.isEmpty { return Lyrics(lines: lines, synced: true, source: "LRCLIB") }
        }
        if let plain = r.plainLyrics, !plain.isEmpty {
            return Lyrics(lines: split(plain), synced: false, source: "LRCLIB")
        }
        return nil
    }

    /// Delegates to the shared parser in AutoMixCore, which is tested and also
    /// strips enhanced-LRC `<mm:ss.xx>` word stamps — previously those were left
    /// sitting in the displayed text.
    private static func parseLRC(_ raw: String) -> [LyricLine] {
        LRC.parse(raw).enumerated().map { i, l in
            LyricLine(at: l.start, text: l.text, id: i, wordStarts: l.wordStarts)
        }
    }

    // MARK: Shared

    private static func split(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines)
            .enumerated()
            .map { LyricLine(at: nil, text: $0.element.trimmingCharacters(in: .whitespaces), id: $0.offset) }
    }

    private static func clean(_ s: String) -> String {
        var out = s
        for pattern in [#"\s*[\(\[][^)\]]*(official|video|audio|lyrics?|visualizer|remaster)[^)\]]*[\)\]]"#,
                        #"\s*-\s*(official|topic)\b.*$"#] {
            out = out.replacingOccurrences(of: pattern, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
