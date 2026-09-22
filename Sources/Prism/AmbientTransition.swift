import SwiftUI

/// How far a song-to-song hand-over has got, for locked mode to draw.
///
/// Follows the audio when a crossfade is running — `Transitions.fadeProgress`
/// is the same `t` the gain ramp uses, so the picture and the sound move
/// together. Without a crossfade there is no fade to follow, so the last 15
/// seconds of the track stand in for one.
enum AmbientTransition {

    static let fallbackWindow: Double = 15

    /// 0…1, or nil when no hand-over is under way.
    @MainActor
    static func progress(model: AppModel, at date: Date) -> Double? {
        if let fade = model.transitions.fadeProgress { return fade }
        guard model.nextEntry != nil else { return nil }
        let d = model.engine.snapshot.duration
        guard d > fallbackWindow * 2 else { return nil }
        let remaining = d - model.engine.smoothTime(at: date)
        guard remaining < fallbackWindow else { return nil }
        return min(max(1 - remaining / fallbackWindow, 0), 1)
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
        // is black. Fading them with the progress keeps the start and end quiet.
        .opacity(min(progress * 3, 1) * min((1 - progress) * 3 + 0.35, 1))
    }

    private func field(_ p: ArtPalette) -> some View {
        LinearGradient(colors: [p.mid.opacity(0.55), p.bottom.opacity(0.35), .black.opacity(0.2)],
                       startPoint: .top, endPoint: .bottom)
    }
}
