import SwiftUI
import Observation

/// Playback quality: what Prism asks for, and what it actually gets.
///
/// The two halves work very differently, and the panel says so rather than
/// presenting one uniform-looking set of switches.
///
/// *Video* is Prism's to set. YouTube sizes the stream to the `<video>` element
/// and Prism collapses that element to nothing outside video mode, so left to
/// itself the player serves 360p on a connection measured at 63 Mbps.
///
/// *Audio* is not. It is an account preference, and the only surface that moves
/// it is YouTube Music's own settings dialog — the player's
/// `setUserAudioQualitySetting` is inert, and there is no InnerTube endpoint for
/// it. So changing it means driving that dialog, which is slower and can fail,
/// and the panel reports what actually happened instead of assuming.
@MainActor
@Observable
final class QualitySettings {

    enum VideoLevel: String, CaseIterable, Identifiable {
        case auto, hd720, hd1080

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto:   return "Auto"
            case .hd720:  return "720p"
            case .hd1080: return "1080p"
            }
        }

        var note: String {
            switch self {
            case .auto:
                return "YouTube decides. Because Prism keeps the video element "
                     + "collapsed until you watch something, that usually means 360p."
            case .hd720:  return "Asks for 720p on every track."
            case .hd1080: return "Asks for 1080p on every track. More data."
            }
        }
    }

    static let audioLevels = ["Low", "Normal", "High"]

    private static let videoKey = "prism.videoQuality"

    private let engine: Engine

    /// nil until the settings dialog has been read once.
    private(set) var audioLevel: String?
    /// A change is in flight. Only a *write* blocks the control — gating on the
    /// read too left the picker dead for the second or two after the panel
    /// opened, which is indistinguishable from it being broken.
    private(set) var audioBusy = false
    /// A read is in flight; shows a spinner but keeps the control live.
    private(set) var audioLoading = false
    private(set) var audioError: String?

    private(set) var stream: StreamQuality?

    var videoLevel: VideoLevel {
        didSet {
            guard videoLevel != oldValue else { return }
            UserDefaults.standard.set(videoLevel.rawValue, forKey: Self.videoKey)
            engine.setVideoQuality(videoLevel.rawValue)
        }
    }

    init(engine: Engine) {
        self.engine = engine
        let saved = UserDefaults.standard.string(forKey: Self.videoKey) ?? ""
        videoLevel = VideoLevel(rawValue: saved) ?? .auto
    }

    /// Pushes the saved preference into a freshly loaded page.
    func applyToEngine() {
        engine.setVideoQuality(videoLevel.rawValue)
    }

    func refresh() {
        Task {
            stream = try? await engine.streamQuality()
            await readAudioLevel()
        }
    }

    private func readAudioLevel() async {
        guard !audioBusy, !audioLoading else { return }
        audioLoading = true
        defer { audioLoading = false }
        do {
            let r = try await engine.audioQuality(set: nil)
            audioLevel = r.current
            audioError = r.ok ? nil : (r.reason ?? "could not read the setting")
        } catch {
            audioError = "could not reach YouTube Music's settings"
        }
    }

    func setAudioLevel(_ want: String) {
        guard !audioBusy else { return }
        // `want != audioLevel` is not a guard here: when the read failed,
        // `audioLevel` is nil and every choice has to stay available.
        guard want != audioLevel else { return }

        // Moved before the await, not after it.
        //
        // Driving the setting takes a second or two, and a segmented picker
        // reads its selection back from this property immediately. Leaving the
        // old value in place meant the segment sprang back to where it was the
        // instant you clicked, which looks exactly like the control refusing
        // the choice. It is put back below if the change really does fail.
        let previous = audioLevel
        audioLevel = want

        Task {
            audioBusy = true
            audioError = nil
            defer { audioBusy = false }
            do {
                let r = try await engine.audioQuality(set: want)
                if r.ok {
                    audioLevel = r.current ?? want
                } else {
                    audioLevel = previous
                    audioError = "YouTube Music did not accept the change"
                }
                // The change only reaches the stream on the next track load, so
                // re-reading now would report the old itag and look like a
                // failure. See the note in the panel.
                stream = try? await engine.streamQuality()
            } catch {
                audioLevel = previous
                audioError = "could not reach YouTube Music's settings"
            }
        }
    }
}
