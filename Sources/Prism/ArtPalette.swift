import SwiftUI

/// Colours pulled out of the current album art, mapped to the equalizer's
/// vertical span: `top` at the peaks, `bottom` at the quietest blocks.
struct ArtPalette: Equatable, Sendable {
    var top: Color
    var mid: Color
    var bottom: Color
    var accent: Color

    static let fallback = ArtPalette(
        top:    Color(red: 0.82, green: 0.84, blue: 0.92),
        mid:    Color(red: 0.52, green: 0.56, blue: 0.68),
        bottom: Color(red: 0.26, green: 0.29, blue: 0.36),
        accent: Color(red: 0.39, green: 0.60, blue: 1.00))

    /// Linear sample across top → mid → bottom. `p` is 0 at the top of the
    /// equalizer's full span and 1 at the bottom.
    func color(at p: Double) -> Color {
        let q = min(max(p, 0), 1)
        return q < 0.5
            ? Self.lerp(top, mid, q * 2)
            : Self.lerp(mid, bottom, (q - 0.5) * 2)
    }

    /// Every colour of `a` moved `t` of the way towards `b`. Used to hand the
    /// rim from one song's colours to the next during a transition.
    static func blend(_ a: ArtPalette, _ b: ArtPalette, _ t: Double) -> ArtPalette {
        let k = min(max(t, 0), 1)
        return ArtPalette(top: lerp(a.top, b.top, k), mid: lerp(a.mid, b.mid, k),
                          bottom: lerp(a.bottom, b.bottom, k),
                          accent: lerp(a.accent, b.accent, k))
    }

    private static func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let x = a.prismRGBA
        let y = b.prismRGBA
        return Color(red:   x.r + (y.r - x.r) * t,
                     green: x.g + (y.g - x.g) * t,
                     blue:  x.b + (y.b - x.b) * t)
    }
}

// MARK: - Extraction

enum ArtworkPalette {
    private static let cache = Cache()

    private actor Cache {
        private var store: [String: ArtPalette] = [:]
        func get(_ key: String) -> ArtPalette? { store[key] }
        func set(_ key: String, _ value: ArtPalette) { store[key] = value }
    }

    static func palette(for urlString: String?) async -> ArtPalette {
        guard let urlString, let url = URL(string: urlString) else { return .fallback }
        // Keyed by image, not URL: the queue's thumbnail and the player's art
        // are one cover at two sizes, and were being fetched and analysed twice.
        let key = ArtworkURL.key(urlString) ?? urlString
        if let hit = await cache.get(key) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = PlatformImage(data: data),
              let cg = image.prismCGImage
        else { return .fallback }

        let result = analyse(cg)
        await cache.set(key, result)
        return result
    }

    /// Downsample to a small grid, then take a dominant colour per horizontal
    /// third. Averaging outright turns colourful art to mud, so pixels are
    /// bucketed by hue and the heaviest bucket wins.
    private static func analyse(_ cg: CGImage) -> ArtPalette {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .fallback }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        let band = side / 3
        var bands: [ArtPalette] = []
        var mostSaturated = (s: 0.0, color: Color.blue)

        for b in 0..<3 {
            // CGContext origin is bottom-left, so band 0 here is the image's top.
            let yStart = side - (b + 1) * band
            let yEnd = side - b * band
            var buckets = [Int: (w: Double, x: Double, y: Double, s: Double, v: Double)]()

            for y in yStart..<yEnd {
                for x in 0..<side {
                    let i = (y * side + x) * 4
                    let r = Double(pixels[i]) / 255
                    let g = Double(pixels[i + 1]) / 255
                    let bl = Double(pixels[i + 2]) / 255
                    let (h, s, v) = hsb(r, g, bl)

                    // Saturated pixels count for more, but not so much that a
                    // small vivid detail beats the large muted field a viewer
                    // actually reads as "the colour of this band".
                    let weight = 0.45 + s
                    let key = s < 0.12 ? -1 : Int(h * 12) % 12
                    var e = buckets[key] ?? (0, 0, 0, 0, 0)
                    e.w += weight
                    // Hue is circular, so accumulate it as a vector.
                    e.x += cos(h * 2 * .pi) * weight
                    e.y += sin(h * 2 * .pi) * weight
                    e.s += s * weight
                    e.v += v * weight
                    buckets[key] = e

                    if s > mostSaturated.s && v > 0.35 {
                        mostSaturated = (s, Color(hue: h, saturation: min(s * 1.1, 1),
                                                  brightness: max(v, 0.55)))
                    }
                }
            }

            guard let winner = buckets.max(by: { $0.value.w < $1.value.w })?.value, winner.w > 0
            else { bands.append(.fallback); continue }

            var hue = atan2(winner.y, winner.x) / (2 * .pi)
            if hue < 0 { hue += 1 }
            let sat = winner.s / winner.w
            let val = winner.v / winner.w

            // Floor and ceiling: art that bottoms out in black (or blows out to
            // white) would otherwise produce blocks that vanish entirely.
            let clampedV = min(max(val, 0.26), 0.94)
            bands.append(ArtPalette(
                top: Color(hue: hue, saturation: min(sat * 1.12, 1), brightness: clampedV),
                mid: .clear, bottom: .clear, accent: .clear))
        }

        // The backdrop is this same artwork, so a faithful palette renders the
        // equalizer nearly invisible against it. Force a wide brightness spread
        // between the bands: the hues stay true to the cover, but the range
        // guarantees the blocks read against whatever is behind them.
        return ArtPalette(
            top:    shape(bands[0].top, brightness: 0.86, saturation: 1.15),
            mid:    shape(bands[1].top, brightness: 0.62, saturation: 1.20),
            bottom: shape(bands[2].top, brightness: 0.34, saturation: 1.25),
            accent: mostSaturated.s > 0.15 ? mostSaturated.color : bands[0].top)
    }

    /// Keeps a colour's hue, retargets its brightness, and nudges saturation.
    private static func shape(_ c: Color, brightness: Double, saturation: Double) -> Color {
        // Hue/saturation/brightness from the sRGB components, computed here
        // rather than via each platform's own getter — `NSColor.getHue` and
        // `UIColor.getHue` disagree about which colour spaces they accept.
        let rgba = c.prismRGBA
        let (h, s, b) = Self.hsb(rgba.r, rgba.g, rgba.b)
        // Blend toward the target rather than snapping to it, so a genuinely
        // dark cover still reads darker than a bright one.
        let targetB = b * 0.35 + brightness * 0.65
        return Color(hue: h,
                     saturation: min(s * saturation, 1),
                     brightness: min(max(targetB, 0.22), 0.97))
    }

    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}
