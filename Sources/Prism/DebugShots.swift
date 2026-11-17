#if canImport(AppKit)
import AppKit
import QuartzCore

/// Debug only (PRISM_EVAL): pictures of things that are otherwise only
/// checkable by eye, written to `~/.prism-eval/`.
@MainActor
enum DebugShots {
    private static var probeLayer: CALayer?
    private static var bench: NSWindow?
    private static weak var benchHost: RimHostView?
    static var benchTicks: Int { benchHost?.debugTicks ?? -1 }

    /// A window behind the desktop — composited, so it can be captured, and
    /// never seen — holding a rim of one flat grey, to measure how bright
    /// each pass really comes out. Returns its window number; 0 closes it.
    static func rimBench(_ mode: Int, palette: ArtPalette = .fallback) -> String {
        bench?.orderOut(nil)
        bench = nil
        guard mode > 0 else { return "rim bench closed" }
        let size = CGSize(width: 700, height: 450)
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: 60, y: 60), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = .black
        w.level = .init(Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let host = RimHostView(frame: CGRect(origin: .zero, size: size))
        w.contentView = host
        let grey: RimSettings.RGBA = (0.5, 0.5, 0.5, 1)
        // 1: the idle drift. 2: playing, steady at full glow (pulse 0).
        // 3: the playing artwork's colours, as the window shows them.
        // 4: the same, moving — breathing; 5: on a 0.5s beat; 6: idle drift.
        let real = mode >= 3
        let cycle = real ? [palette.top, palette.accent, palette.mid].map(\.prismRGBA) : [grey, grey, grey]
        host.debugAlwaysSeen = mode >= 4
        host.settings = RimSettings(cycle: cycle, accent: grey, drift: mode == 1 || mode == 6,
                                    thickness: real ? 2 : 5, glow: real ? 0.7 : 1,
                                    corner: 12, inset: real ? 7 : 10, animating: mode >= 4,
                                    beatPeriod: mode == 5 ? 0.5 : nil, pulse: mode >= 4 ? 0.8 : 0,
                                    hearing: false, flow: true)
        benchHost = host
        w.orderFrontRegardless()
        bench = w
        return "rim bench \(mode) window \(w.windowNumber)"
    }

    /// Adds one animating test layer to the frontmost full-screen window, to
    /// learn what the render server charges for: 1 a small layer, 2 a
    /// display-sized layer, 3 a display-sized shape with a short stroke,
    /// 4 a small conic gradient with moving colours, 5 the same display-sized.
    static func probe(_ kind: Int) -> String {
        probeLayer?.removeFromSuperlayer()
        probeLayer = nil
        guard kind > 0, let host = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 1200 && $0.level.rawValue > 1000 })?
            .contentView?.layer else { return "probe removed" }
        let full = host.bounds
        func pulse(_ l: CALayer, _ key: String, _ from: Any, _ to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from; a.toValue = to
            a.duration = 1; a.autoreverses = true; a.repeatCount = .infinity
            l.add(a, forKey: "probe")
        }
        let layer: CALayer
        switch kind {
        case 1:
            layer = CALayer(); layer.frame = CGRect(x: 300, y: 300, width: 10, height: 10)
            layer.backgroundColor = CGColor(gray: 1, alpha: 1)
            pulse(layer, "opacity", 0.2, 0.6)
        case 6, 7, 8:
            // A stepped animation: 10, 30 or 5 changes a second.
            layer = CALayer(); layer.frame = CGRect(x: 300, y: 300, width: 10, height: 10)
            layer.backgroundColor = CGColor(gray: 1, alpha: 1)
            let rate = kind == 6 ? 10 : kind == 7 ? 30 : 5
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = (0..<(rate * 4)).map { NSNumber(value: 0.2 + 0.4 * Double($0 % rate) / Double(rate)) }
            a.calculationMode = .discrete
            a.duration = 4; a.repeatCount = .infinity
            layer.add(a, forKey: "probe")
        case 2:
            layer = CALayer(); layer.frame = full
            layer.backgroundColor = CGColor(gray: 1, alpha: 0.02)
            pulse(layer, "opacity", 0.2, 0.6)
        case 3:
            let s = CAShapeLayer(); s.frame = full
            let p = CGMutablePath(); p.move(to: CGPoint(x: 200, y: 200)); p.addLine(to: CGPoint(x: 600, y: 200))
            s.path = p; s.strokeColor = CGColor(gray: 1, alpha: 0.6); s.lineWidth = 3; s.fillColor = nil
            pulse(s, "strokeEnd", 0.2, 1.0)
            layer = s
        default:
            let g = CAGradientLayer(); g.type = .conic
            g.frame = kind == 4 ? CGRect(x: 300, y: 300, width: 80, height: 80) : full
            g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
            let a = [CGColor(red: 1, green: 0, blue: 0, alpha: 0.3), CGColor(red: 0, green: 0, blue: 1, alpha: 0.3),
                     CGColor(red: 1, green: 0, blue: 0, alpha: 0.3)]
            let b = [CGColor(red: 0, green: 0, blue: 1, alpha: 0.3), CGColor(red: 1, green: 0, blue: 0, alpha: 0.3),
                     CGColor(red: 0, green: 0, blue: 1, alpha: 0.3)]
            g.colors = a
            pulse(g, "colors", a, b)
            layer = g
        }
        host.addSublayer(layer)
        probeLayer = layer
        return "probe \(kind) on \(Int(full.width))x\(Int(full.height))"
    }

    /// The layer equalizer at the Now Playing size, lit by its decorative
    /// motion, rendered from its real layer tree.
    static func equalizer(_ palette: ArtPalette, to url: URL) -> String {
        let size = CGSize(width: 420, height: 240), scale: CGFloat = 2
        let view = EqualizerBarsView(frame: CGRect(origin: .zero, size: size))
        view.apply(EqualizerLook(top: palette.top.prismRGBA, mid: palette.mid.prismRGBA,
                                 bottom: palette.bottom.prismRGBA, mirrored: false, seed: 137,
                                 maxBlocks: 6, block: 5, gap: 2.5, fps: 15, playing: false))
        view.layoutSubtreeIfNeeded()
        view.debugStep()
        guard let layer = view.layer, let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no context" }
        ctx.setFillColor(red: 0.16, green: 0.12, blue: 0.10, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        // The view is flipped; a bitmap context is not.
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return "no image" }
        try? data.write(to: url)
        return "equalizer shot: \(layer.sublayers?.count ?? 0) layers -> \(url.lastPathComponent)"
    }
}
#endif
