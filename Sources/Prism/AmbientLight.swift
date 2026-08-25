import SwiftUI

/// A line of light drawn around a rectangle's perimeter, coloured by the
/// current artwork.
///
/// One view serves all three places it appears: the rim inside the window, the
/// rim in compact mode, and the full-screen ambient surface. Only the geometry
/// and the strength differ.
///
/// **One `Canvas`, not stacked blurred shapes.** The lesson from `EqualizerView`
/// applies here verbatim, and harder: a SwiftUI `.blur` on a full-screen view is
/// an offscreen gaussian *every frame*, and at full-display size that alone
/// would cost more than the two equalizers did before their halo was merged.
/// `ctx.addFilter(.blur(radius:))` inside a single `Canvas` keeps the whole
/// thing to one layer, and the three passes share one path.
///
/// The motion is deliberately slow and has no transient to miss, so it runs at
/// 30fps rather than the display's rate, and stops entirely when there is
/// nothing to light.
struct AmbientLight: View {
    let palette: ArtPalette
    /// False dims the light and drains its colour — see `drift`.
    var isPlaying: Bool = true
    /// Width of the crisp line, in points.
    var thickness: CGFloat = 2
    /// 0…1. Scales the bleed, not the line.
    var glow: Double = 0.7
    var corner: CGFloat = 12
    /// How far in from the edge the line sits.
    var inset: CGFloat = 7
    /// Stops the clock when the light cannot be seen.
    var animating: Bool = true
    /// Seconds per beat, when the track's tempo is known and beat motion is on.
    /// Nil falls back to the slow breath.
    var beatPeriod: Double? = nil
    /// How deep the modulation goes, 0…1. 0 holds a steady line.
    var pulse: Double = 0.38

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ring(at: t)
        }
        .allowsHitTesting(false)
    }

    /// Nothing playing keeps the line and drops the colour: a slow colourless
    /// drift rather than the last track's palette left burning on screen.
    private var drift: Bool { !isPlaying }

    private var colours: [Color] {
        let live = [palette.top, palette.accent, palette.mid, palette.top]
        guard drift else { return live }
        // Desaturated towards the neutral fallback rather than to grey, so the
        // line keeps some depth instead of going flat.
        return live.map { ArtPalette.desaturated($0, amount: 0.9) }
    }

    /// The modulation the line rides on.
    ///
    /// With a tempo known, the shape is a struck note rather than a sine: a
    /// fast rise on the beat and a decay over the rest of it. That is what
    /// makes it read as *to* the beat instead of merely near it. No audio is
    /// analysed for this — the BPM is the one AutoMix already looks up, so the
    /// pulse costs nothing and needs no new permission.
    private func breath(at t: TimeInterval) -> Double {
        guard !drift else { return 0.7 }
        let depth = min(max(pulse, 0), 1)
        let shape: Double
        if let period = beatPeriod, period > 0.15 {
            let phase = (t.truncatingRemainder(dividingBy: period)) / period
            shape = pow(1 - phase, 2.2)
        } else {
            // 7.4s breath, matching the mock's `rimBreathe`.
            shape = 0.5 + 0.5 * sin(t * 2 * .pi / 7.4)
        }
        return (1 - depth) + depth * shape
    }

    private func ring(at t: TimeInterval) -> some View {
        // A full turn every 28s while playing, slowed right down when idle.
        let period: Double = drift ? 60 : 28
        let angle = Angle.degrees((t / period * 360).truncatingRemainder(dividingBy: 360))
        let strength = (drift ? 0.4 : glow) * breath(at: t)

        return Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            guard size.width > inset * 2 + 4, size.height > inset * 2 + 4 else { return }
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let path = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)
            let shading = GraphicsContext.Shading.conicGradient(
                Gradient(colors: colours),
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                angle: angle)

            // Widest and softest first, crisp line last. Each pass takes its own
            // copy of the context: a filter added to `ctx` is not removable, so
            // sharing one would blur the crisp stroke too.
            var wide = ctx
            wide.addFilter(.blur(radius: 24))
            wide.opacity = 0.45 * strength
            wide.stroke(path, with: shading, lineWidth: thickness * 10)

            var near = ctx
            near.addFilter(.blur(radius: 8))
            near.opacity = 0.55 * strength
            near.stroke(path, with: shading, lineWidth: thickness * 3.5)

            var line = ctx
            line.opacity = min(1, 0.75 + 0.25 * strength)
            line.stroke(path, with: shading, lineWidth: thickness)
        }
    }
}

extension ArtPalette {
    /// Pulls a colour towards its own brightness, losing the hue. Used for the
    /// nothing-playing drift.
    static func desaturated(_ c: Color, amount: Double) -> Color {
        let p = c.prismRGBA
        let luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b
        let k = min(max(amount, 0), 1)
        return Color(red: p.r + (luma - p.r) * k,
                     green: p.g + (luma - p.g) * k,
                     blue: p.b + (luma - p.b) * k)
    }
}
