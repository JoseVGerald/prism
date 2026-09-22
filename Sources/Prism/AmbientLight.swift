import SwiftUI

/// The music, reduced to what the light reacts to. All 0…1.
struct AudioBands: Equatable, Sendable {
    var level: Double = 0
    var bass: Double = 0
    var mid: Double = 0
    var treble: Double = 0
    /// When the last hit landed, for the comet that runs round the rim.
    var onsetAt: Date?
    /// Seconds per beat, heard from the audio itself; nil until a steady
    /// pulse has held for a couple of seconds.
    var tempo: Double?
    /// When a beat landed — any beat; the rest fall every `tempo` from it.
    var beatAt: Date?

    static let silent = AudioBands()
}

/// Anything that can say what the music is doing right now. On macOS that is
/// `LiveAudio`; iOS has no route to another process's audio, so it has none
/// and the light simply breathes.
@MainActor
protocol AudioBandsSource: AnyObject {
    var bands: AudioBands { get }
}

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
    /// When set, the light reacts to the music itself rather than breathing or
    /// following a tempo. Sampled every frame from inside the timeline — see
    /// `LiveAudio.bands` for why it is not observed.
    var audio: (any AudioBandsSource)? = nil
    /// A light that keeps running round the rim at the song's tempo.
    var flow: Bool = false
    /// The looked-up tempo, seconds per beat, whatever the motion setting: the
    /// flowing line's pace when the audio itself is not being heard.
    var tempo: Double? = nil

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ring(at: t)
            }
            // Rasterised and blurred by Metal. Left to itself a Canvas draws on
            // the CPU into a window-sized bitmap, three blurred passes of it,
            // thirty times a second.
            .drawingGroup()
            if flow {
                FlowLine(accent: drift ? ArtPalette.desaturated(palette.accent, amount: 0.9)
                                       : palette.accent,
                         playing: isPlaying, thickness: thickness, inset: inset,
                         corner: corner, animating: animating, pulse: pulse,
                         tempo: tempo, audio: audio)
            }
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
        let live = drift ? nil : audio?.bands
        // A full turn every 28s while playing, slowed right down when idle.
        // The colour goes round at one steady pace: a lap every 28s while
        // playing, slowed right down when idle. Nothing the music does changes
        // it — the treble used to lean it back and forth.
        let period: Double = drift ? 60 : 28
        let phase = (t / period).truncatingRemainder(dividingBy: 1)
        let cycle = colours.dropLast().map(\.prismRGBA)
        let strength: Double = {
            guard let live else { return (drift ? 0.4 : glow) * breath(at: t) }
            // Bass carries the brightness. A floor keeps the line alive through
            // quiet passages instead of blinking out between hits.
            let depth = min(max(pulse, 0.25), 1)
            return glow * ((1 - depth) * 0.55 + depth * (0.25 + 0.95 * live.bass))
        }()
        let swell = 1 + 0.7 * (live?.bass ?? 0)
        let onsetAge = live?.onsetAt.map { Date().timeIntervalSince($0) }

        return Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            guard size.width > inset * 2 + 4, size.height > inset * 2 + 4 else { return }
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let path = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)
            let shading = GraphicsContext.Shading.conicGradient(
                Self.evenGradient(cycle, phase: phase, in: rect),
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                angle: .zero)

            // Widest and softest first, crisp line last. Each pass takes its own
            // copy of the context: a filter added to `ctx` is not removable, so
            // sharing one would blur the crisp stroke too.
            var wide = ctx
            wide.addFilter(.blur(radius: 24))
            // The bleed swells with the bass through opacity, never lineWidth:
            // animating a stroke width re-tessellates the path every frame.
            wide.opacity = min(0.45 * strength * swell, 1)
            wide.stroke(path, with: shading, lineWidth: thickness * 10)

            var near = ctx
            near.addFilter(.blur(radius: 8))
            near.opacity = 0.55 * strength
            near.stroke(path, with: shading, lineWidth: thickness * 3.5)

            var line = ctx
            line.opacity = min(1, 0.75 + 0.25 * strength)
            line.stroke(path, with: shading, lineWidth: thickness)

            // A hit sends a bright comet a third of the way round the rim from
            // the top, fading as it travels. A trimmed copy of the same path, so
            // it costs one more stroke for the ~0.6s it is alive.
            // With the flowing line on, a hit flares the line instead.
            if !flow, let age = onsetAge, age < 0.6 {
                let k = age / 0.6
                let head = 0.02 + k * 0.33
                let comet = path.trimmedPath(from: max(head - 0.06, 0), to: head)
                var flare = ctx
                flare.addFilter(.blur(radius: 6))
                flare.opacity = (1 - k) * 0.9
                flare.stroke(comet, with: .color(palette.accent), lineWidth: thickness * 4)
                var core = ctx
                core.opacity = (1 - k)
                core.stroke(comet, with: .color(.white), lineWidth: thickness * 1.2)
            }
        }
    }
}

extension AmbientLight {

    /// A conic gradient whose colours travel along the rim at constant speed.
    ///
    /// Turning a conic gradient turns it at a constant *angle*, and on a wide
    /// rectangle a degree covers far more rim at the middle of a long side
    /// than near a corner — so the colour raced along some stretches and
    /// crawled along others. Instead the gradient stays still and its stops
    /// are recoloured each frame: for each angle, find where that ray meets
    /// the rim, how far round the rim that is, and which colour belongs there
    /// now. Clockwise, the way the flowing line runs.
    static func evenGradient(_ cycle: [(r: Double, g: Double, b: Double, a: Double)],
                             phase: Double, in rect: CGRect) -> Gradient {
        guard cycle.count > 1 else { return Gradient(colors: [.white]) }
        let hw = Double(rect.width / 2), hh = Double(rect.height / 2)
        let perimeter = 4 * (hw + hh)
        let steps = 48
        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(steps + 1)
        for k in 0...steps {
            let theta = Double(k) / Double(steps) * 2 * .pi   // clockwise from 3 o'clock
            let (c, s) = (cos(theta), sin(theta))
            let tx = abs(c) > 1e-9 ? hw / abs(c) : .infinity
            let ty = abs(s) > 1e-9 ? hh / abs(s) : .infinity
            let x = c * min(tx, ty), y = s * min(tx, ty)
            // Distance round the rim, clockwise from the middle of the right side.
            let along: Double
            if tx <= ty {
                along = c > 0 ? (y >= 0 ? y : 3 * hh + 4 * hw + (y + hh))
                              : hh + 2 * hw + (hh - y)
            } else {
                along = s > 0 ? hh + (hw - x) : 3 * hh + 2 * hw + (x + hw)
            }
            var u = (along / perimeter - phase) * Double(cycle.count)
            u = u - (u / Double(cycle.count)).rounded(.down) * Double(cycle.count)
            let i = Int(u) % cycle.count, j = (i + 1) % cycle.count, f = u - Double(Int(u))
            let a = cycle[i], b = cycle[j]
            stops.append(.init(color: Color(red: a.r + (b.r - a.r) * f,
                                            green: a.g + (b.g - a.g) * f,
                                            blue: a.b + (b.b - a.b) * f),
                               location: Double(k) / Double(steps)))
        }
        return Gradient(stops: stops)
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
