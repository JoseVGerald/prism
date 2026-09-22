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

/// Fetches lyrics, preferring ones that are actually timed.
///
/// YouTube only ever returns a flat block of text — verified against the web,
/// iOS Music and Android Music client contexts, all of which come back with
/// `serializedLyricInfo` and no cue ranges. LRCLIB is a free, keyless, public
/// lyrics database that does publish LRC timings, so it is tried first and
/// YouTube is the fallback. The only thing sent off-machine is the track title,
/// artist, album and duration.
@MainActor
enum LyricsService {

    private static var cache: [String: Lyrics] = [:]

    static func lyrics(for track: Track, engine: Engine) async -> Lyrics {
        if let hit = cache[track.videoId] { return hit }

        if let synced = await lrclib(track) {
            cache[track.videoId] = synced
            return synced
        }
        let fallback = await youtube(track, engine: engine)
        cache[track.videoId] = fallback
        return fallback
    }

    /// Looks a coming track up ahead of time. LRCLIB only, and cached only on
    /// a hit: the YouTube fallback reads the page, which is still on the
    /// current song, so running it early could file the wrong lyrics.
    static func prefetch(_ track: Track) async {
        guard cache[track.videoId] == nil, let synced = await lrclib(track) else { return }
        cache[track.videoId] = synced
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

    // MARK: YouTube fallback

    private static func youtube(_ track: Track, engine: Engine) async -> Lyrics {
        guard let r = try? await engine.lyrics(videoId: track.videoId),
              let text = r.text, !text.isEmpty
        else { return Lyrics(lines: [], synced: false, source: "") }
        return Lyrics(lines: split(text), synced: false, source: r.source ?? "YouTube Music")
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
