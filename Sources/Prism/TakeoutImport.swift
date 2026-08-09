import Foundation

/// Reads a Google Takeout watch history and turns it into plays.
///
/// This exists because YouTube's own API will not give you your listening
/// past. `FEmusic_history` answers, but it is deduplicated, carries no
/// timestamps, and has no continuation tokens — it stops dead at about two
/// weeks. Takeout is the only source that hands over the real thing: one entry
/// per play, each with an exact timestamp, going back years.
///
/// What it still does not hand over is **duration**. Takeout records that you
/// played something, never how long you stayed. So every imported play is
/// marked `.imported` and carries a stand-in length, and the dashboard is
/// expected to say "about" wherever those are counted. Play counts, artists,
/// first-played dates and streaks are all exact; only the hours are estimated.
///
/// Export from <https://takeout.google.com>, selecting **YouTube and YouTube
/// Music** and, inside it, only *history*. The file wanted is
/// `Takeout/YouTube and YouTube Music/history/watch-history.json`.
enum TakeoutImport {

    struct Result {
        /// Entries that were YouTube Music plays with a usable video ID.
        var parsed: Int
        /// Of those, how many were not already in the log.
        var added: Int
        /// Entries skipped because the video had been removed or made private,
        /// which Takeout writes as a placeholder with no URL.
        var unavailable: Int
        /// Entries that were plain YouTube rather than YouTube Music.
        var notMusic: Int
        var earliest: Date?
        var latest: Date?
    }

    enum Failure: LocalizedError {
        case unreadable
        case notJSON
        case noMusicEntries(total: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file could not be read."
            case .notJSON:
                return "That does not look like a Takeout history file. Pick watch-history.json."
            case .noMusicEntries(let total):
                return total == 0
                    ? "That history file is empty."
                    : "Found \(total) entries but no YouTube Music plays. If you exported only "
                    + "YouTube, re-export with YouTube Music included."
            }
        }
    }

    /// One row of `watch-history.json`.
    ///
    /// Everything is optional because Takeout omits fields freely: a removed
    /// video has no `titleUrl` and no `subtitles`, and older exports predate
    /// some keys entirely. A strict model fails the whole file on one bad row.
    private struct Entry: Decodable {
        var header: String?
        var title: String?
        var titleUrl: String?
        var time: String?
        var subtitles: [Subtitle]?

        struct Subtitle: Decodable {
            var name: String?
        }
    }

    /// Parses off the main actor — a real export is tens of megabytes and
    /// hundreds of thousands of rows.
    static func read(_ url: URL) throws -> ([Play], Result) {
        // Mapped rather than copied: the raw bytes are the biggest single cost
        // of an import and there is no reason to hold them twice.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw Failure.unreadable
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            throw Failure.notJSON
        }

        let stamps = ISO8601DateFormatter()
        stamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainStamps = ISO8601DateFormatter()
        plainStamps.formatOptions = [.withInternetDateTime]

        var plays: [Play] = []
        var unavailable = 0
        var notMusic = 0

        for entry in entries {
            guard isMusic(entry) else { notMusic += 1; continue }
            guard let urlString = entry.titleUrl, let videoId = videoId(from: urlString) else {
                // "Watched a video that has been removed" — a real play, but
                // there is nothing left to attribute it to.
                unavailable += 1
                continue
            }
            guard let raw = entry.time,
                  let at = stamps.date(from: raw) ?? plainStamps.date(from: raw) else { continue }

            plays.append(Play(videoId: videoId,
                              title: cleanTitle(entry.title),
                              artist: cleanArtist(entry.subtitles?.first?.name),
                              artworkURL: nil,
                              at: at,
                              seconds: Play.assumedLength,
                              source: .imported))
        }

        guard !plays.isEmpty else {
            throw Failure.noMusicEntries(total: entries.count)
        }

        let result = Result(parsed: plays.count, added: 0,
                            unavailable: unavailable, notMusic: notMusic,
                            earliest: plays.map(\.at).min(),
                            latest: plays.map(\.at).max())
        return (plays, result)
    }

    // MARK: Field cleaning

    /// Takeout tags YouTube Music rows in the header, but old exports and some
    /// locales do not, so the URL is checked as a fallback.
    private static func isMusic(_ entry: Entry) -> Bool {
        if entry.header == "YouTube Music" { return true }
        return entry.titleUrl?.contains("music.youtube.com") == true
    }

    private static func videoId(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        let id = components.queryItems?.first { $0.name == "v" }?.value
        // Video IDs are always 11 characters; anything else is a channel or
        // playlist link that happened to carry a `v`.
        guard let id, id.count == 11 else { return nil }
        return id
    }

    /// Rows read "Watched <title>" — or "Listened to <title>" in some music
    /// exports. Neither prefix is part of the song.
    private static func cleanTitle(_ raw: String?) -> String {
        var text = raw ?? ""
        for prefix in ["Watched ", "Listened to "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Auto-generated artist channels are named "<Artist> - Topic", which is
    /// YouTube's plumbing showing through and not what anyone calls the artist.
    private static func cleanArtist(_ raw: String?) -> String {
        var text = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(" - Topic") { text.removeLast(" - Topic".count) }
        return text
    }
}
