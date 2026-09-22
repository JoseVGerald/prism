import SwiftUI

/// How far a song-to-song hand-over has got, for locked mode to draw.
///
/// Follows the audio when a crossfade is running: worked out every frame from
/// the fade's own start and length, so the picture moves with the sound and
/// as smoothly as the display allows. Without a crossfade there is no fade to
/// follow, so the last 15 seconds of the track stand in for one.
enum AmbientTransition {

    static let fallbackWindow: Double = 15

    /// 0…1, or nil when no hand-over is under way.
    @MainActor
    static func progress(model: AppModel, at date: Date, latch: Latch) -> Double? {
        let raw: Double? = {
            if let clock = model.transitions.fadeClock {
                return min(max(date.timeIntervalSince(clock.began) / clock.length, 0), 1)
            }
            guard model.nextEntry != nil else { return nil }
            let d = model.engine.snapshot.duration
            guard d > fallbackWindow * 2 else { return nil }
            let remaining = d - model.engine.smoothTime(at: date)
            guard remaining < fallbackWindow else { return nil }
            return min(max(1 - remaining / fallbackWindow, 0), 1)
        }()
        return latch.hold(raw, current: model.engine.snapshot.track?.videoId,
                          next: model.nextEntry?.videoId, at: date)
    }

    /// Keeps a finished hand-over at 1 until the song has actually changed.
    ///
    /// The fade ends, and the fallback's clock runs out, a moment before the
    /// engine reports the new track — the handover waits for YouTube to
    /// advance. Without this the picture sprang back to the old song for that
    /// moment and then jumped to the new one. A class held in `@State` so it
    /// can remember across frames without being state a frame writes to.
    @MainActor
    final class Latch {
        private var waitingFor: String?
        private var since = Date.distantPast

        var holding: Bool { waitingFor != nil }

        func hold(_ p: Double?, current: String?, next: String?, at date: Date) -> Double? {
            if let w = waitingFor {
                // Arrived — or it never will (a skip failed): let go either way.
                if current == w || date.timeIntervalSince(since) > 4 { waitingFor = nil }
                else { return 1 }
            }
            if let p, p >= 0.97, let next { waitingFor = next; since = date }
            return p
        }
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The screen split between the two songs: the outgoing song's colour on the
/// left, the incoming one's on the right, with a soft boundary that sweeps
/// across as the new song takes the screen over.
struct TransitionFields: View {
    let from: ArtPalette
    let to: ArtPalette
    /// 0…1, already eased.
    let progress: Double

    var body: some View {
        let edge = 1 - progress          // where the boundary sits, 0…1 across
        ZStack {
            field(from)
            field(to)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: max(edge - 0.16, 0)),
                        .init(color: .black, location: min(edge + 0.16, 1))
                    ], startPoint: .leading, endPoint: .trailing)
                }
        }
        // The fields only exist while a hand-over runs; outside one, locked mode
        // is black. They fade in over the first third and out over the last,
        // reaching nothing exactly as the song changes — they used to stop at
        // 35% and vanish from there in one frame.
        .opacity(min(progress * 3, 1) * min((1 - progress) * 3, 1))
    }

    private func field(_ p: ArtPalette) -> some View {
        LinearGradient(colors: [p.mid.opacity(0.55), p.bottom.opacity(0.35), .black.opacity(0.2)],
                       startPoint: .top, endPoint: .bottom)
    }
}
