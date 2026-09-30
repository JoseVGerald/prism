import Foundation

// MARK: - Player state pushed up from the web engine

/// Mirrors the YouTube IFrame player state codes.
enum PlaybackState: Int, Codable {
    case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3, cued = 5

    var isPlaying: Bool { self == .playing || self == .buffering }
}

struct Track: Codable, Identifiable, Hashable {
    var videoId: String
    var title: String
    var artist: String
    var album: String?
    var durationText: String?
    var durationSeconds: Double?
    var artworkURL: String?
    /// Carries YouTube's explicit badge.
    var explicit: Bool?
    /// Which search shelf this came from — "Top result", "Songs", "Videos" and
    /// so on. Nil outside search. Ranking uses it to keep user-uploaded
    /// reposts below the real releases.
    var shelf: String?

    var id: String { videoId }
}

struct QueueEntry: Codable, Identifiable, Hashable {
    var index: Int
    var videoId: String
    var title: String
    var artist: String
    var durationText: String?
    var artworkURL: String?
    var selected: Bool
    var videoType: String?
    var explicit: Bool?
    /// The other half of this track's Song/Video pair, if YouTube ships one.
    var counterpartId: String?
    var counterpartType: String?

    // The queue can legitimately contain the same video twice, so the index has
    // to be part of the identity or SwiftUI collapses the duplicates.
    var id: String { "\(index)-\(videoId)" }
}

/// One snapshot of everything the engine knows, posted on every tick.
struct EngineSnapshot: Codable {
    var ready: Bool
    var signedIn: Bool
    var state: Int
    var currentTime: Double
    var duration: Double
    var volume: Double
    var muted: Bool
    var repeatMode: String?
    var shuffled: Bool?
    /// MUSIC_VIDEO_TYPE_* for whichever side is actually playing.
    var videoType: String?
    /// The id of the other side of the Song/Video pair, when there is one.
    var counterpartId: String?
    /// Whether the page is currently styled for fullscreen video.
    var videoMode: Bool?
    /// Where the video actually paints inside the page, in CSS pixels.
    var videoRect: VideoRect?
    var track: Track?
    var queue: [QueueEntry]
    var queueIndex: Int
    /// What the top of the bridge's undo stack would put back, if anything.
    var undoLabel: String?

    var playback: PlaybackState { PlaybackState(rawValue: state) ?? .unstarted }

    /// ATV is the audio-track version — a static image, nothing worth watching.
    /// Anything else (OMV, UGC, official uploads) carries real picture.
    var hasVideo: Bool {
        guard let t = videoType else { return false }
        return t != "MUSIC_VIDEO_TYPE_ATV"
    }

    /// True when the track exists as both a song and a music video, so the two
    /// can be switched between. Independent of `hasVideo`: a song played from
    /// an album is ATV — no picture of its own — and still pairs with a video.
    var hasCounterpart: Bool { counterpartId != nil }

    /// Whether the picture, rather than the audio-only version, is on screen.
    var showingVideoSide: Bool { hasVideo }
}

// MARK: - Search / browse results

struct SearchResults: Codable {
    var songs: [Track]
    var albums: [Shelf]
    var artists: [Shelf]
    var playlists: [Shelf]
    /// YouTube's own "Top result" card — the thing it thinks you meant. For a
    /// query like "octane" that is the album, not the first track inside it.
    var topShelf: Shelf?
    var topTrack: Track?
}

/// A non-song result (album, artist, playlist) that we navigate into rather than play.
struct Shelf: Codable, Identifiable, Hashable {
    var browseId: String
    var title: String
    var subtitle: String?
    var artworkURL: String?
    var kind: String

    var id: String { browseId }
}

struct LibrarySection: Codable, Identifiable, Hashable {
    var title: String
    var items: [Shelf]

    var id: String { title }
}

/// What actually happened when we asked YouTube to enqueue something. The
/// dispatcher lies about success, so this is measured, not assumed.
struct EnqueueResult: Codable {
    var ok: Bool
    var before: Int
    var after: Int
    var usedRealEndpoint: Bool
    var hijackedPlayback: Bool
}

/// The video's painted rectangle and the viewport containing it, in CSS pixels.
///
/// YouTube will not let the picture be repositioned inside the page, so Prism
/// measures where it lands and slides the whole webview instead.
struct VideoRect: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double
    var vw: Double, vh: Double

    /// Page-space insets around the video, as a fraction of the viewport.
    var insets: (left: Double, top: Double, right: Double, bottom: Double) {
        (x / max(vw, 1),
         y / max(vh, 1),
         max(vw - (x + w), 0) / max(vw, 1),
         max(vh - (y + h), 0) / max(vh, 1))
    }
}

/// Where to put the webview so the video lands on the window.
///
/// Explicit size and offset rather than something derived from a measurement at
/// render time: the page moves the video whenever the webview is resized, so
/// the only reliable placement is one that has been measured *after* being
/// applied and then corrected.
struct VideoPlacement: Equatable {
    var width: Double
    var height: Double
    var dx: Double
    var dy: Double
}

/// Result of asking YouTube to download a track for offline playback.
/// `supported` is false when the web player exposes no download action at all.
struct DownloadResult: Codable {
    var supported: Bool
    var ok: Bool
    var reason: String
}

/// One recorded queue change, and who caused it. Debug only — see the queue
/// tracing block in `Bridge.swift`.
struct QueueTrace: Codable {
    var cause: String
    var shape: String
    var index: String?
    var playing: String?
    var added: [String]?
    var removed: [String]?
    var head: [String]?
}

struct QueueTraceEnvelope: Codable {
    var trace: QueueTrace?
}

/// Result of reading or setting YouTube Music's account audio quality.
struct AudioQualityResult: Codable {
    var ok: Bool
    /// "Low", "Normal" or "High", or nil when the setting could not be read.
    var current: String?
    var changed: Bool?
    var reason: String?
}

/// What the player is actually pulling down, as opposed to what was asked for.
struct StreamQuality: Codable {
    var audioItag: Int?
    var videoItag: Int?
    var audioCodec: String?
    /// Average bits per second of the audio stream in flight.
    var audioBitrate: Int?
    /// The best the manifest offers, so "you are not on the top tier" is a fact
    /// rather than a guess.
    var bestAudioBitrate: Int?
    var resolution: String?
    var videoQuality: String?

    var audioKbps: Int? { audioBitrate.map { $0 / 1000 } }
    var bestAudioKbps: Int? { bestAudioBitrate.map { $0 / 1000 } }

    /// Reads "640x360@24 / 640x360@24" down to "640x360".
    var shortResolution: String? {
        resolution?.split(separator: "/").first?
            .split(separator: "@").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

/// Contents of one opened playlist / album.
struct PlaylistDetail: Codable {
    var title: String
    var subtitle: String?
    /// Present for albums and playlists; lets the whole thing be queued at once.
    var playlistId: String?
    var artworkURL: String?
    var tracks: [Track]
    /// Carousels below the track list — an artist's albums, singles and videos.
    /// Empty for a plain album or playlist, which is only a list of songs.
    var sections: [DetailSection]?
    /// "artist", "album" or "playlist", so the view knows what it is showing.
    var kind: String?
}

/// A titled row of cards inside a detail page.
struct DetailSection: Codable, Identifiable, Hashable {
    var title: String
    var items: [Shelf]

    var id: String { title }
}

/// Which kind of result the search is currently showing.
///
/// These are YouTube's own filter chips. `params` is what its web client sends
/// for each, and passing it back gets a properly filtered response rather than
/// the unfiltered one sliced up locally — the unfiltered search does not even
/// contain albums or artists, so filtering client-side could not work.
enum SearchScope: String, CaseIterable, Identifiable, Codable {
    case all, songs, videos, albums, artists, playlists

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .videos: "Music videos"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }

    var params: String? {
        switch self {
        case .all: nil
        case .songs: "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
        case .videos: "EgWKAQIQAWoKEAkQChAFEAMQBA=="
        case .albums: "EgWKAQIYAWoKEAkQChAFEAMQBA=="
        case .artists: "EgWKAQIgAWoKEAkQChAFEAMQBA=="
        case .playlists: "EgWKAQIoAWoKEAkQAxAEEAkQBQ=="
        }
    }
}

// MARK: - Messages the JS bridge sends us

enum BridgeMessage {
    case snapshot(EngineSnapshot)
    case searchResults(requestId: String, results: SearchResults)
    case library(requestId: String, sections: [LibrarySection])
    case playlist(requestId: String, detail: PlaylistDetail)
    case error(requestId: String?, message: String)
}

/// One of your playlists — somewhere songs can be added.
struct MyPlaylist: Codable, Identifiable, Hashable {
    /// Without the "VL" a page's browseId carries.
    var playlistId: String
    var title: String
    var subtitle: String?
    var artworkURL: String?

    var id: String { playlistId }
}
