import Foundation
import Observation

/// What is playing, for views: one observable property per fact.
///
/// `Engine.snapshot` is replaced whole about once a second, because the
/// playback position is in it. Anything that read a field of it in a view's
/// body — the title, the queue, whether it is playing — was therefore redrawn
/// every second with it: the queue's rows, the transport, the notch island,
/// the window's root, and the app's menus rebuilt, sixty times a minute for a
/// song that had not changed. Measured with the window not even on screen,
/// that was most of a steady 9% of a core.
///
/// Here each fact is stored on its own and written only when it differs, so
/// a view is redrawn for what it reads and nothing else. The names match
/// `EngineSnapshot`, so a view says `snap.track` either way.
@MainActor
@Observable
final class PlayerState {
    private(set) var ready = false
    private(set) var signedIn = false
    private(set) var state = -1
    private(set) var currentTime = 0.0
    private(set) var duration = 0.0
    private(set) var volume = 100.0
    private(set) var muted = false
    private(set) var repeatMode: String? = "NONE"
    private(set) var shuffled: Bool? = false
    private(set) var videoType: String?
    private(set) var counterpartId: String?
    private(set) var videoMode: Bool?
    private(set) var videoRect: VideoRect?
    private(set) var track: Track?
    private(set) var queue: [QueueEntry] = []
    private(set) var queueIndex = -1
    private(set) var undoLabel: String?

    var playback: PlaybackState { PlaybackState(rawValue: state) ?? .unstarted }
    /// Playing or buffering — stored, so a flip between those two (every
    /// track change does it) redraws nothing that only asks "is it playing".
    private(set) var isPlaying = false

    var hasVideo: Bool {
        guard let t = videoType else { return false }
        return t != "MUSIC_VIDEO_TYPE_ATV"
    }
    var hasCounterpart: Bool { counterpartId != nil }
    var showingVideoSide: Bool { hasVideo }

    /// The entry after the one playing, if there is one.
    var nextEntry: QueueEntry? {
        let i = queueIndex + 1
        return i > 0 && i < queue.count ? queue[i] : nil
    }

    func take(_ s: EngineSnapshot) {
        if ready != s.ready { ready = s.ready }
        if signedIn != s.signedIn { signedIn = s.signedIn }
        if state != s.state { state = s.state }
        if isPlaying != s.playback.isPlaying { isPlaying = s.playback.isPlaying }
        if currentTime != s.currentTime { currentTime = s.currentTime }
        if duration != s.duration { duration = s.duration }
        if volume != s.volume { volume = s.volume }
        if muted != s.muted { muted = s.muted }
        if repeatMode != s.repeatMode { repeatMode = s.repeatMode }
        if shuffled != s.shuffled { shuffled = s.shuffled }
        if videoType != s.videoType { videoType = s.videoType }
        if counterpartId != s.counterpartId { counterpartId = s.counterpartId }
        if videoMode != s.videoMode { videoMode = s.videoMode }
        if videoRect != s.videoRect { videoRect = s.videoRect }
        if track != s.track { track = s.track }
        if queueIndex != s.queueIndex { queueIndex = s.queueIndex }
        if undoLabel != s.undoLabel { undoLabel = s.undoLabel }
        if queue != s.queue { queue = s.queue }
    }
}
