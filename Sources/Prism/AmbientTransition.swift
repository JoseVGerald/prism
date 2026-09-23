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
    static func progress(model: AppModel, at date: Date, handover: Handover) -> Double? {
        let current = model.engine.snapshot.track?.videoId
        let raw: Double? = {
            if let clock = model.transitions.fadeClock {
                // The fade outlives its song by a second or two while the two
                // players are lined up. Once the song it fades *from* is gone
                // the hand-over is over as far as the picture goes — read on,
                // it looked like a finished fade into whatever is next now.
                guard clock.from == nil || clock.from == current else { return nil }
                return min(max(date.timeIntervalSince(clock.began) / clock.length, 0), 1)
            }
            guard model.nextEntry != nil else { return nil }
            let d = model.engine.snapshot.duration
            guard d > fallbackWindow * 2 else { return nil }
            let remaining = d - model.engine.smoothTime(at: date)
            guard remaining < fallbackWindow else { return nil }
            return min(max(1 - remaining / fallbackWindow, 0), 1)
        }()
        return handover.update(raw, model: model, at: date)
    }

    /// Which song a hand-over is going to, and holding it there until it has
    /// actually arrived.
    ///
    /// **Pinned when the hand-over starts.** "The entry after the current one"
    /// is not stable through a song change: YouTube sometimes moves the queue
    /// on a couple of seconds before it reports the new song, and for that
    /// moment the entry after the *old* song is the song after the new one.
    /// Read live, the incoming card and colours jumped to that song for ~2.5s.
    ///
    /// **Held at 1 until arrival.** The fade ends, and the fallback's clock
    /// runs out, a moment before the engine reports the new track; without the
    /// hold the picture sprang back to the old song and then jumped.
    ///
    /// A class held in `@State`, so it can remember across frames without
    /// being state a frame writes to.
    @MainActor
    final class Handover {
        /// The song being handed to, and its colours.
        private(set) var incoming: QueueEntry?
        private(set) var incomingPalette: ArtPalette = .fallback
        private var outgoing: String?
        private var holdingSince: Date?
        /// Set when a hand-over completes; nothing new is pinned until the
        /// progress has been idle once, so a finished hand-over can never be
        /// mistaken for the start of the next one.
        private var settling = false

        var holding: Bool { holdingSince != nil }

        func update(_ raw: Double?, model: AppModel, at date: Date) -> Double? {
            let current = model.engine.snapshot.track?.videoId

            if let since = holdingSince, let target = incoming?.videoId {
                // Arrived, or something else is playing now (a skip), or it
                // never came: let go — otherwise stay finished.
                let moved = current != outgoing && current != target
                guard current == target || moved || date.timeIntervalSince(since) > 4 else { return 1 }
                holdingSince = nil
                incoming = nil
                settling = true
                return nil
            }

            guard let raw, raw > 0 else { incoming = nil; settling = false; return raw }
            if settling { return nil }
            if incoming == nil, let next = model.nextEntry, next.videoId != current {
                incoming = next
                outgoing = current
            }
            // Colours may arrive after the pin; take them while the queue
            // still agrees which song is next, and keep them once it doesn't.
            if let pinned = incoming, model.nextEntry?.videoId == pinned.videoId {
                incomingPalette = model.nextPalette
            }
            if raw >= 0.97, incoming != nil { holdingSince = date }
            return raw
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
