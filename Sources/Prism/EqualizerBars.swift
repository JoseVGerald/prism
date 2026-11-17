#if canImport(AppKit)
import SwiftUI
import AppKit
import QuartzCore

/// What an equalizer is built from. A change to anything but `playing`
/// repaints or rebuilds it.
struct EqualizerLook: Equatable {
    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)
    var top: RGBA, mid: RGBA, bottom: RGBA
    var mirrored: Bool
    var seed: Double
    var maxBlocks: Int
    var block: CGFloat
    var gap: CGFloat
    var fps: Double
    var playing: Bool

    static func == (l: EqualizerLook, r: EqualizerLook) -> Bool {
        l.sameBars(as: r) && l.playing == r.playing && l.fps == r.fps
    }

    /// Whether the same picture would be drawn, whatever is moving it.
    func sameBars(as r: EqualizerLook) -> Bool {
        top == r.top && mid == r.mid && bottom == r.bottom && mirrored == r.mirrored
            && seed == r.seed && maxBlocks == r.maxBlocks && block == r.block && gap == r.gap
    }

    /// The palette's colour a fraction `p` of the way down.
    func color(at p: Double) -> RGBA {
        let q = min(max(p, 0), 1)
        func lerp(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
            (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
        }
        return q < 0.5 ? lerp(top, mid, q * 2) : lerp(mid, bottom, (q - 0.5) * 2)
    }
}

struct EqualizerHost: NSViewRepresentable {
    let look: EqualizerLook
    let audio: (any AudioBandsSource)?

    func makeNSView(context: Context) -> EqualizerBarsView { EqualizerBarsView() }
    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.audio = audio
        view.apply(look)
    }
}

/// The block equalizer, moved by Core Animation.
///
/// Every column is the same picture — a full stack of lit blocks, coloured by
/// height — seen through a window that opens and closes about the middle. The
/// picture is painted once, when the artwork's colours or the size change;
/// after that a frame is nothing but "this column's window is now this tall",
/// which the render server applies. As a SwiftUI canvas on a timeline, each
/// frame re-ran the view, re-laid-out its host and repainted every block: the
/// three columns in the notch alone kept the main thread about a sixth busy,
/// all day, behind every other app.
final class EqualizerBarsView: NSView {
    weak var audio: (any AudioBandsSource)?

    private var look: EqualizerLook?
    private var timer: Timer?
    private var occlusion: NSObjectProtocol?

    /// Per column: the soft halo behind, and the rimmed blocks in front.
    private var halos: [CALayer] = []
    private var cores: [CALayer] = []
    /// The height each column is showing, in blocks either side of centre.
    private var shown: [Int] = []
    private var grid: Grid?
    /// What the layers were last painted for.
    private var painted: (look: EqualizerLook, size: CGSize, scale: CGFloat)?

    /// How far each pass reaches beyond its block, as the canvas drew them.
    private static let haloPad: CGFloat = 3, rimPad: CGFloat = 1.1

    private struct Grid {
        var columns: Int, peak: Int
        var pitch: CGFloat, x0: CGFloat, cy: CGFloat
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ new: EqualizerLook) {
        guard new != look else { return }
        look = new
        repaintIfNeeded()
        retime()
    }

    override func layout() {
        super.layout()
        repaintIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        repaintIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        if let window {
            // A window nobody can see is the cheapest place to stop.
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.retime() }
            }
        }
        repaintIfNeeded()
        retime()
    }

    // MARK: Ticking

    /// Runs the timer only while there is something to move and someone to
    /// see it.
    private func retime() {
        let wanted = look?.playing == true && window?.occlusionState.contains(.visible) == true
            && grid != nil
        guard wanted else {
            timer?.invalidate()
            timer = nil
            return
        }
        // Hearing the song, at least 20 a second: slower and the bars visibly
        // lag the hits they are showing.
        let fps = audio == nil ? (look?.fps ?? 15) : max(look?.fps ?? 15, 20)
        let interval = 1 / fps
        if let timer, abs(timer.timeInterval - interval) < 0.0005 { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval * 0.15
        // Common modes, so the bars keep moving under a menu or a drag.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Steps taken and bars moved by every equalizer, for the debug log.
    static var debugTicks = 0, debugMoves = 0

    private func tick() {
        Self.debugTicks += 1
        guard let look, let grid else { return }
        let spectrum = audio?.bands.spectrum ?? []
        let t = Date.timeIntervalSinceReferenceDate
        var changed = false
        for c in 0..<grid.columns {
            let a = spectrum.isEmpty ? Self.drift(c, t, seed: look.seed)
                                     : Self.heard(spectrum, column: c, of: grid.columns,
                                                  mirrored: look.mirrored)
            let h = Int((a * Double(grid.peak)).rounded())
            guard shown[c] != h else { continue }
            Self.debugMoves += 1
            if !changed {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                changed = true
            }
            show(h, in: c, grid)
        }
        if changed { CATransaction.commit() }
    }

    /// One step of the motion without a timer, for a debug picture.
    func debugStep() { tick() }

    private func show(_ h: Int, in c: Int, _ grid: Grid) {
        guard let look else { return }
        shown[c] = h
        let reach = CGFloat(h) * grid.pitch + look.block / 2
        cores[c].bounds.size.height = 2 * (reach + Self.rimPad)
        halos[c].bounds.size.height = 2 * (reach + Self.haloPad)
    }

    // MARK: Painting

    /// Rebuilds the columns when the size or the block geometry changed, and
    /// repaints their picture when only the colours did.
    private func repaintIfNeeded() {
        guard let look, let host = layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = bounds.size
        if let p = painted, p.look.sameBars(as: look), p.size == size, p.scale == scale { return }

        let pitch = look.block + look.gap
        guard pitch > 0, size.width > pitch, size.height > pitch else {
            (halos + cores).forEach { $0.removeFromSuperlayer() }
            halos = []; cores = []; shown = []; grid = nil; painted = nil
            retime()
            return
        }
        let columns = max(1, Int(size.width / pitch))
        let used = CGFloat(columns) * pitch - look.gap
        // Row count follows the available height so bars fill their frame.
        let rows = max(3, Int(size.height / pitch))
        let peak = min(look.maxBlocks, (rows - 1) / 2)
        let new = Grid(columns: columns, peak: peak, pitch: pitch,
                       x0: (size.width - used) / 2, cy: size.height / 2)

        let (halo, core) = Self.strips(look, peak: peak, scale: scale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if halos.count != columns {
            (halos + cores).forEach { $0.removeFromSuperlayer() }
            halos = (0..<columns).map { _ in Self.window() }
            cores = (0..<columns).map { _ in Self.window() }
            // Every halo under every block, as the canvas painted them.
            halos.forEach(host.addSublayer)
            cores.forEach(host.addSublayer)
            shown = Array(repeating: -1, count: columns)
        }
        let heights = shown
        self.grid = new
        for c in 0..<columns {
            let x = new.x0 + CGFloat(c) * pitch + look.block / 2
            for (layer, image, width) in [(halos[c], halo, pitch),
                                          (cores[c], core, look.block + 2 * Self.rimPad)] {
                layer.contents = image
                layer.contentsScale = scale
                layer.position = CGPoint(x: x, y: new.cy)
                layer.bounds.size.width = width
            }
            // Keep what was showing; a column new to the world starts lit by
            // one block, as a silent bar is.
            show(min(max(heights[c], 0), peak), in: c, new)
        }
        CATransaction.commit()
        painted = (look, size, scale)
        retime()
    }

    /// A column's window: its picture stays put about the centre while the
    /// bounds open and close on it.
    private static func window() -> CALayer {
        let l = CALayer()
        l.contentsGravity = .center
        l.masksToBounds = true
        l.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        return l
    }

    /// One full column, every block lit, painted twice over: the halo, and the
    /// dark rim with the crisp block on it. Colour follows height only, so one
    /// pair serves every column.
    private static func strips(_ look: EqualizerLook, peak: Int, scale: CGFloat) -> (CGImage?, CGImage?) {
        let pitch = look.block + look.gap
        let reach = CGFloat(peak) * pitch + look.block / 2
        // The gradient is anchored to the full possible span, so short
        // columns stay in the low colours and only tall ones reach the top.
        let spanH = (CGFloat(peak) * 2 + 1) * pitch

        func paint(width: CGFloat, pad: CGFloat, _ draw: (CGContext, _ top: CGFloat, _ fraction: Double) -> Void) -> CGImage? {
            let height = 2 * (reach + pad)
            let w = Int((width * scale).rounded(.up)), h = Int((height * scale).rounded(.up))
            guard w > 0, h > 0, let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            // Top-left origin, in points, with the picture centred in the bitmap.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: (CGFloat(w) / scale - width) / 2, y: (CGFloat(h) / scale - height) / 2)
            for r in -peak...peak {
                let top = height / 2 + CGFloat(r) * pitch - look.block / 2
                let y = CGFloat(r) * pitch - look.block / 2 + (CGFloat(peak) + 0.5) * pitch
                draw(ctx, top, Double(y / spanH))
            }
            return ctx.makeImage()
        }
        func fill(_ ctx: CGContext, _ c: EqualizerLook.RGBA, _ alpha: Double) {
            ctx.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: alpha)
        }

        // The halo: a band the full width of the column's cell, so the halos
        // of neighbouring lit blocks join into one, as a run of them did.
        let halo = paint(width: pitch, pad: haloPad) { ctx, top, f in
            fill(ctx, look.color(at: f), 0.20)
            ctx.fill(CGRect(x: 0, y: top - haloPad, width: pitch, height: look.block + 2 * haloPad))
        }
        // A dark rim that stops the blocks dissolving into a backdrop made
        // from the very same artwork, then the block.
        let coreWidth = look.block + 2 * rimPad
        let core = paint(width: coreWidth, pad: rimPad) { ctx, top, f in
            let rim = CGRect(x: 0, y: top - rimPad, width: coreWidth, height: coreWidth)
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.45)
            ctx.addPath(CGPath(roundedRect: rim, cornerWidth: coreWidth * 0.3,
                               cornerHeight: coreWidth * 0.3, transform: nil))
            ctx.fillPath()
            fill(ctx, look.color(at: f), 1)
            ctx.addPath(CGPath(roundedRect: rim.insetBy(dx: rimPad, dy: rimPad),
                               cornerWidth: look.block * 0.3, cornerHeight: look.block * 0.3,
                               transform: nil))
            ctx.fillPath()
        }
        return (halo, core)
    }

    // MARK: Heights

    /// The column's slice of the spectrum, interpolated between bands. A
    /// sliver of floor keeps a quiet band from vanishing entirely.
    static func heard(_ spectrum: [Double], column: Int, of columns: Int, mirrored: Bool) -> Double {
        var x = (Double(column) + 0.5) / Double(columns)
        if mirrored { x = 1 - x }
        let pos = x * Double(spectrum.count - 1)
        let i = Int(pos), f = pos - Double(i)
        let v = spectrum[i] + (spectrum[min(i + 1, spectrum.count - 1)] - spectrum[i]) * f
        return min(max(v, 0.04), 1)
    }

    /// Layered sines at incommensurate rates: organic, non-repeating, cheap.
    static func drift(_ column: Int, _ t: Double, seed: Double) -> Double {
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
#endif
