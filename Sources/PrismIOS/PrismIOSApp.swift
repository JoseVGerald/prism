import SwiftUI
import AVFoundation
import WebKit

/// Prism for iPhone.
///
/// The same app: the same engine driving the same `music.youtube.com` through
/// the same injected bridge, the same queue mechanics, history, stats, search
/// ranking and AutoMix. Only the surface is rebuilt, because a sidebar, a
/// side-by-side queue and a hover-revealed transport are desktop ideas and
/// none of them survive a phone.
///
/// What is deliberately absent, rather than faked:
///
/// * **The notch island.** Its macOS implementation is a borderless `NSPanel`
///   positioned against `auxiliaryTopLeftArea`. iOS has a Dynamic Island, but
///   it is reached through ActivityKit Live Activities — a different feature
///   with a different lifecycle, not a port of this one.
/// * **Output switching.** CoreAudio's default-device API does not exist here;
///   routing belongs to the system and to AirPlay.
/// * **The system-audio probe.** ScreenCaptureKit is macOS-only, and no iOS
///   API hands one app another's audio.
/// * **Compact mode and the desktop blur**, which are both about windows.
@main
struct PrismIOSApp: App {

    @State private var model = AppModel()

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(model: model)
                .preferredColorScheme(.dark)
        }
    }

    /// Declares Prism as a playback app: correct interruption behaviour, and
    /// it ignores the ringer switch.
    ///
    /// **This does not buy background audio, and it is worth recording why.**
    /// The audio is decoded in WebKit's WebContent process, not this one, and
    /// WebKit interrupts its own media on background as a matter of policy:
    ///
    ///     MediaElementSession::beginInterruption(... type = EnteringBackground)
    ///     WebProcessProxy::updateAudibleMediaAssertions: Releasing MediaPlayback assertion
    ///
    /// Three things were tried and measured. `UIBackgroundModes: audio` plus an
    /// active session — the *app* process does survive (verified: still running
    /// at 1:24 elapsed while backgrounded), but WebKit cuts the media anyway. A
    /// silent `AVAudioEngine` keep-alive to make this process an audible-media
    /// client — no change, so it was removed rather than left burning battery
    /// for nothing. Picture-in-Picture, the one sanctioned route for web media
    /// to continue in the background — `webkitSupportsPresentationMode(
    /// 'picture-in-picture')` returns **false** for YouTube's element.
    ///
    /// The only remaining route would be extracting the stream and playing it
    /// through `AVPlayer`, which is exactly what this project refuses to do:
    /// no extraction is the reason nothing here breaks when YouTube changes.
    /// So on iPhone, playback is foreground-only, and that is a property of the
    /// architecture rather than a bug to be fixed.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers` so the keep-alive source in BackgroundAudio and
            // the webview's own playback can coexist instead of interrupting
            // each other.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // Nothing actionable here: the app still runs, it just will not
            // survive being backgrounded. Reported rather than swallowed.
            NSLog("[PRISM] audio session failed: \(error.localizedDescription)")
        }
    }
}
