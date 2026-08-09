import Foundation
import MediaPlayer

/// Publishes the current track to macOS and accepts the media keys back.
///
/// The webview also registers itself as a Now Playing source, so without this
/// the system shows "music.youtube.com" and a stale title. Registering our own
/// commands takes ownership of the keys and the Control Center tile.
@MainActor
final class NowPlaying {

    private weak var engine: Engine?
    private var artworkURL: String?
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?

    init(engine: Engine) {
        self.engine = engine
        wireCommands()
    }

    private func wireCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget { [weak self] _ in
            self?.engine?.play(); return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            self?.engine?.pause(); return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.engine?.togglePlayPause(); return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.engine?.next(); return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            self?.engine?.previous(); return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.engine?.seek(to: e.positionTime)
            return .success
        }
        // Skip commands are what the AirPods double-tap and some keyboards send.
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in
            guard let e = self?.engine else { return .commandFailed }
            e.seek(to: e.snapshot.currentTime + 15); return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            guard let e = self?.engine else { return .commandFailed }
            e.seek(to: max(e.snapshot.currentTime - 15, 0)); return .success
        }

        for cmd in [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand,
                    c.nextTrackCommand, c.previousTrackCommand,
                    c.changePlaybackPositionCommand, c.skipForwardCommand,
                    c.skipBackwardCommand] {
            cmd.isEnabled = true
        }
        // Nothing here is a rating or a like, and leaving them enabled puts
        // dead buttons in Control Center.
        for cmd in [c.likeCommand, c.dislikeCommand, c.bookmarkCommand,
                    c.changeRepeatModeCommand, c.changeShuffleModeCommand] {
            cmd.isEnabled = false
        }
    }

    /// Mirrors a snapshot into the system's Now Playing info.
    func update(_ snap: EngineSnapshot) {
        let center = MPNowPlayingInfoCenter.default()

        guard let track = snap.track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snap.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: snap.playback.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if snap.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = snap.duration }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        center.nowPlayingInfo = info
        center.playbackState = snap.playback.isPlaying ? .playing : .paused

        loadArtwork(track.artworkURL)
    }

    /// Must be `nonisolated`. MediaPlayer calls the request handler on its own
    /// dispatch queue while building the Now Playing dictionary; building the
    /// artwork inside a `@MainActor` context makes Swift insert an isolation check
    /// into that closure, which trips `dispatch_assert_queue` and takes the
    /// whole app down with a SIGTRAP the moment artwork is published.
    private nonisolated static func makeArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func loadArtwork(_ url: String?) {
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        artworkTask?.cancel()
        guard let url, let u = URL(string: url) else { return }

        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: u),
                  let image = PlatformImage(data: data),
                  !Task.isCancelled, let self, self.artworkURL == url
            else { return }
            self.artwork = Self.makeArtwork(image)
            // Re-publish so the art appears without waiting for the next tick.
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = self.artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
