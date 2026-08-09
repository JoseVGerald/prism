import SwiftUI

/// Decorative block equalizer flanking the cover art.
///
/// Deliberately not tied to the audio: the sound lives inside the engine's
/// webview and tapping it risks breaking playback. Column heights are smooth
/// layered sine noise with no positional envelope — every column has the same
/// expected amplitude ("taper C").
struct EqualizerView: View {
    let palette: ArtPalette
    let isPlaying: Bool
    /// Offsets the noise so the left and right sides never mirror each other.
    var seed: Double = 0
    var maxBlocks: Int = 8
    var block: CGFloat = 7
    var gap: CGFloat = 3

    var body: some View {
        // One Canvas, no SwiftUI blur. Blurred glow layers meant an offscreen
        // gaussian every frame for each of two equalizers, which sat at ~30%
        // CPU forever. The halo below is painted instead, for the same look at
        // a fraction of the cost. Paused freezes the timeline entirely.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { tl in
            blocks(tl.date.timeIntervalSinceReferenceDate)
        }
        .allowsHitTesting(false)
    }

    private func blocks(_ t: Double) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let pitch = block + gap
            guard pitch > 0, size.width > pitch, size.height > pitch else { return }

            let columns = max(1, Int(size.width / pitch))
            let used = CGFloat(columns) * pitch - gap
            let x0 = (size.width - used) / 2
            let cy = size.height / 2

            // Row count follows the available height so bars fill their frame.
            let rows = max(3, Int(size.height / pitch))
            let peak = min(maxBlocks, (rows - 1) / 2)

            // The gradient is anchored to the full possible span, not to each
            // column, so short columns stay in the low colours and only tall
            // ones reach the top of the palette.
            let spanTop = cy - (CGFloat(peak) + 0.5) * pitch
            let spanH = (CGFloat(peak) * 2 + 1) * pitch

            var heights = [Int](repeating: 0, count: columns)
            for c in 0..<columns {
                heights[c] = Int((amplitude(c, t) * Double(peak)).rounded())
            }

            // Painted in three passes: a soft colour halo, a dark rim that stops
            // the blocks dissolving into a backdrop made from the very same
            // artwork, then the crisp block.
            //
            // Batched by row rather than per block. Block colour depends only
            // on y, so every block in a row shares a shading and can go into
            // one Path — turning thousands of fill calls per frame into a few
            // dozen.
            func pass(pad: CGFloat, tint: (Double) -> GraphicsContext.Shading) {
                for r in -peak...peak {
                    let y = cy + CGFloat(r) * pitch - block / 2
                    var path = Path()
                    let radius = (block + pad * 2) * 0.3
                    for c in 0..<columns where heights[c] >= abs(r) {
                        let x = x0 + CGFloat(c) * pitch
                        path.addRoundedRect(
                            in: CGRect(x: x - pad, y: y - pad,
                                       width: block + pad * 2, height: block + pad * 2),
                            cornerSize: CGSize(width: radius, height: radius))
                    }
                    if path.isEmpty { continue }
                    ctx.fill(path, with: tint(Double((y - spanTop) / spanH)))
                }
            }

            pass(pad: 3.0) { .color(palette.color(at: $0).opacity(0.20)) }
            pass(pad: 1.1) { _ in .color(.black.opacity(0.45)) }
            pass(pad: 0.0) { .color(palette.color(at: $0)) }
        }
    }

    /// Layered sines at incommensurate rates: organic, non-repeating, cheap.
    private func amplitude(_ column: Int, _ t: Double) -> Double {
        let s = Double(column) * 1.73 + seed
        let v = sin(t * 1.9 + s) * 0.5
              + sin(t * 3.1 + s * 1.9) * 0.3
              + sin(t * 0.8 + s * 0.6) * 0.2
        // Push toward the extremes so the shape reads as peaks and troughs
        // rather than a uniform band.
        let n = (v + 1) / 2
        let shaped = n < 0.5 ? 2 * n * n : 1 - 2 * (1 - n) * (1 - n)
        return min(max(shaped, 0.05), 1)
    }
}
