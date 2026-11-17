#if canImport(AppKit)
import SwiftUI
import AppKit
import QuartzCore
import Accelerate

/// Everything the rim is drawn from.
struct RimSettings: Equatable {
    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)
    /// The colours that go round, in order; the last runs back into the first.
    var cycle: [RGBA]
    var accent: RGBA
    /// Nothing playing: dimmer, slower, and steady.
    var drift: Bool
    var thickness: CGFloat
    var glow: Double
    var corner: CGFloat
    var inset: CGFloat
    var animating: Bool
    var beatPeriod: Double?
    var pulse: Double
    /// The light reacts to the audio rather than breathing or keeping a beat.
    var hearing: Bool
    /// A hit flares the flowing line instead of sending a comet.
    var flow: Bool

    static func == (l: RimSettings, r: RimSettings) -> Bool {
        l.sameColours(as: r) && l.sameShape(as: r) && l.drift == r.drift && l.glow == r.glow
            && l.animating == r.animating && l.beatPeriod == r.beatPeriod && l.pulse == r.pulse
            && l.hearing == r.hearing && l.flow == r.flow
    }

    func sameColours(as r: RimSettings) -> Bool {
        accent == r.accent && cycle.count == r.cycle.count && zip(cycle, r.cycle).allSatisfy { $0 == $1 }
    }

    func sameShape(as r: RimSettings) -> Bool {
        thickness == r.thickness && corner == r.corner && inset == r.inset
    }

    /// How many times a second the light has to be touched to look as it
    /// should. Every touch is a frame the window server composites, so this
    /// is as low as each kind of motion allows: the colour's lap takes half a
    /// minute, a breath seven seconds; only a beat or the audio needs thirty.
    var rate: Double {
        guard animating else { return 0 }
        if drift { return 4 }
        if hearing { return 30 }
        if let b = beatPeriod, b > 0.15 { return 30 }
        return 15
    }
}

struct RimHost: NSViewRepresentable {
    let settings: RimSettings
    let audio: (any AudioBandsSource)?

    func makeNSView(context: Context) -> RimHostView { RimHostView() }
    func updateNSView(_ view: RimHostView, context: Context) {
        view.audio = audio
        view.settings = settings
    }
}

final class RimHostView: NSView {
    let rim = RimLayer()
    weak var audio: (any AudioBandsSource)?
    private var timer: Timer?
    private var occlusion: NSObjectProtocol?

    /// As asked for. What the layer is given also knows whether the window
    /// can be seen at all.
    var settings: RimSettings? { didSet { push() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(rim)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Top-left origin: the colour runs clockwise, as the flowing line does.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        rim.contentsScale = window?.backingScaleFactor ?? 2
        rim.resize(to: bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        if let window {
            // Behind another window, a screen saver or a sleeping display,
            // the light is not drawn — so it is not moved either.
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.push() }
            }
        }
        push()
    }

    /// Debug (PRISM_EVAL): treat this view's window as seen even where it
    /// cannot be, so the hidden test bench moves.
    var debugAlwaysSeen = false
    /// Timer ticks, for the debug log.
    private(set) var debugTicks = 0

    private func push() {
        guard var s = settings else { return }
        let seen = debugAlwaysSeen || window?.occlusionState.contains(.visible) == true
        s.animating = s.animating && seen
        rim.apply(s)

        let rate = s.rate
        guard rate > 0 else {
            timer?.invalidate()
            timer = nil
            return
        }
        if let timer, abs(timer.timeInterval - 1 / rate) < 0.0005 { return }
        timer?.invalidate()
        let t = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.debugTicks += 1
                self.rim.step(self.audio?.bands)
            }
        }
        t.tolerance = 0.1 / rate
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

/// The rim of light, as Core Animation layers.
///
/// Three passes of one rounded rectangle, as the canvas painted them — a wide
/// soft bleed, a nearer glow, and the crisp line — but as *masks*: the two
/// glows blurred once, when the size changes, instead of on every frame. All
/// three share one conic gradient seen through them, so a frame is at most
/// "these stops are now these colours" and "these passes are now this
/// bright", set from a timer that runs only as fast as the motion needs.
///
/// Not animations run by the render server, though that was tried first: it
/// runs them at the display's rate, and in a display-sized window every
/// frame anything changes costs the window server about the same whatever
/// changed — measured, a 10pt square fading in and out in the ambient
/// window cost it as much as the whole rim. So what matters is how many
/// frames change, and nothing here changes more often than it must.
///
/// As a SwiftUI canvas on a timeline this was a window-sized — in ambient
/// mode, display-sized — repaint with two gaussian blurs thirty times a
/// second: about a sixth of the main thread and a third of a window-server
/// core for as long as it was on screen, playing or not.
final class RimLayer: CALayer {

    /// The gradient, seen through `passes`.
    private let lit = CALayer()
    private let gradient = CAGradientLayer()
    private let passes = CALayer()
    private let wideMask = CALayer(), nearMask = CALayer(), lineMask = CAShapeLayer()
    /// A hit's comet: a soft flare in the accent, and a white core.
    private let flare = CAShapeLayer(), core = CAShapeLayer()

    private var settings: RimSettings?
    /// The size and shape the glow masks were blurred for.
    private var maskedFor: (size: CGSize, shape: RimSettings)?
    private var remask: DispatchWorkItem?
    private var lastOnset: Date?

    /// How far round the colour has got, and when that was worked out.
    private var phase = 0.0
    private var colouredAt: CFTimeInterval = 0
    private var shown: (wide: Float, near: Float, line: Float) = (-1, -1, -1)

    private static let stops = 64
    /// The gradient is drawn this many times smaller than the window and
    /// stretched: it is smooth everywhere but its centre, which the masks
    /// hide.
    private static let shrink: CGFloat = 6

    override init() {
        super.init()
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = (0...Self.stops).map { NSNumber(value: Double($0) / Double(Self.stops)) }
        gradient.magnificationFilter = .linear
        lit.addSublayer(gradient)
        lit.mask = passes
        for m in [wideMask, nearMask] {
            m.contentsGravity = .resize
            m.magnificationFilter = .linear
        }
        lineMask.fillColor = nil
        lineMask.strokeColor = CGColor(gray: 0, alpha: 1)
        [wideMask, nearMask, lineMask].forEach(passes.addSublayer)
        addSublayer(lit)
        for l in [flare, core] {
            l.fillColor = nil
            l.lineCap = .round
            l.opacity = 0
            addSublayer(l)
        }
        core.strokeColor = CGColor(gray: 1, alpha: 1)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Inputs

    func resize(to bounds: CGRect) {
        guard frame != bounds else { return }
        withoutActions {
            frame = bounds
            for l in [lit, passes, wideMask, nearMask, lineMask, flare, core] { l.frame = bounds }
            gradient.transform = CATransform3DIdentity
            gradient.bounds = CGRect(x: 0, y: 0, width: bounds.width / Self.shrink,
                                     height: bounds.height / Self.shrink)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            gradient.transform = CATransform3DMakeScale(Self.shrink, Self.shrink, 1)
        }
        reshape()
        // The stops are placed by the rectangle's proportions.
        colour()
    }

    func apply(_ new: RimSettings) {
        let old = settings
        settings = new
        guard let old else {
            reshape(); colour(); brighten(nil)
            return
        }
        guard old != new else { return }
        if !old.sameShape(as: new) { reshape() }
        // Carries on from wherever the colour had got to, so a new song or a
        // new pace never makes it jump.
        if !old.sameColours(as: new) || old.drift != new.drift || old.animating != new.animating {
            colour()
        }
        brighten(nil)
    }

    /// One tick of the timer: moves the colour on when it has moved far
    /// enough to see, and sets how bright the light is now.
    func step(_ bands: AudioBands?) {
        guard let s = settings, s.animating, !isHidden else { return }
        // A tenth of a second is under a hundredth of the way from one
        // colour to the next; idling, the colour takes its time anyway.
        if CACurrentMediaTime() - colouredAt >= (s.drift ? 0.24 : 0.099) { colour() }
        brighten(bands)

        if s.hearing, !s.drift, let at = bands?.onsetAt, at != lastOnset {
            lastOnset = at
            if !s.flow, at.timeIntervalSinceNow > -0.1 { comet() }
        }
    }

    // MARK: Shape

    private func reshape() {
        guard let s = settings, bounds.width > s.inset * 2 + 4, bounds.height > s.inset * 2 + 4 else {
            withoutActions { isHidden = true }
            return
        }
        let rect = bounds.insetBy(dx: s.inset, dy: s.inset)
        let path = Path(roundedRect: rect, cornerRadius: s.corner, style: .continuous).cgPath
        withoutActions {
            isHidden = false
            lineMask.path = path
            lineMask.lineWidth = s.thickness
            for l in [lineMask, flare, core] { l.contentsScale = contentsScale }
            // The comet runs clockwise from the top, a third of the way round.
            let run = Rim(rect: rect, corner: s.corner).path(laps: 1)
            flare.path = run
            flare.lineWidth = s.thickness * 4
            flare.strokeColor = CGColor(srgbRed: s.accent.r, green: s.accent.g, blue: s.accent.b, alpha: 0.9)
            flare.shadowColor = flare.strokeColor
            flare.shadowRadius = 6
            flare.shadowOpacity = 1
            flare.shadowOffset = .zero
            core.path = run
            core.lineWidth = s.thickness * 1.2
        }

        // The glows' masks are the costly part — a blur each — so while the
        // size is still changing the old ones are stretched to fit, and the
        // new ones are made once it has stopped.
        let first = maskedFor == nil
        remask?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.blurMasks() }
        remask = work
        if first { work.perform() } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    private func blurMasks() {
        guard let s = settings, !isHidden else { return }
        if let m = maskedFor, m.size == bounds.size, m.shape.sameShape(as: s) { return }
        let rect = bounds.insetBy(dx: s.inset, dy: s.inset)
        let path = Path(roundedRect: rect, cornerRadius: s.corner, style: .continuous).cgPath
        // Blurred this far, nothing finer than a couple of points survives,
        // so the masks are made small and stretched: a quarter and a half
        // of the points, not the display's pixels.
        let wideImage = Self.blurredStroke(path, size: bounds.size, lineWidth: s.thickness * 10,
                                           blur: 24, scale: 0.25)
        let nearImage = Self.blurredStroke(path, size: bounds.size, lineWidth: s.thickness * 3.5,
                                           blur: 8, scale: 0.5)
        withoutActions {
            wideMask.contents = wideImage
            nearMask.contents = nearImage
        }
        maskedFor = (bounds.size, s)
    }

    /// The stroke of `path`, gaussian-blurred, as an image whose alpha is the
    /// mask. `scale` is pixels per point.
    private static func blurredStroke(_ path: CGPath, size: CGSize, lineWidth: CGFloat,
                                      blur: CGFloat, scale: CGFloat) -> CGImage? {
        // Drawn with room round the edge for the half of the stroke that
        // falls outside the window, and cut back to the window afterwards:
        // that half is not seen, but its light spreads back in. Blurring a
        // stroke already cut off at the edge left the bleed a third dimmer
        // than the canvas painted it.
        let margin = Int((lineWidth / 2 * scale).rounded(.up)) + 1
        let iw = max(Int((size.width * scale).rounded(.up)), 1)
        let ih = max(Int((size.height * scale).rounded(.up)), 1)
        let w = iw + 2 * margin, h = ih + 2 * margin
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        // Top-left origin, to match the flipped view the mask sits in.
        ctx.translateBy(x: CGFloat(margin), y: CGFloat(h - margin))
        ctx.scaleBy(x: CGFloat(iw) / size.width, y: -CGFloat(ih) / size.height)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(lineWidth)
        ctx.addPath(path)
        ctx.strokePath()

        // Three box blurs make a gaussian to within a few percent. A box has
        // to be an odd number of pixels wide, which at these sizes is a
        // coarse choice — so the three need not match: as many of the wider
        // one as bring the spread closest to the one asked for.
        let sigma = Double(blur * scale)
        let ideal = sqrt(4 * sigma * sigma + 1)
        var narrow = UInt32(ideal.rounded(.down))
        if narrow % 2 == 0 { narrow -= 1 }
        let spread = { (wider: Int) -> Double in
            let a = Double(narrow * narrow) - 1, b = Double((narrow + 2) * (narrow + 2)) - 1
            return (Double(3 - wider) * a + Double(wider) * b) / 12
        }
        let wider = (0...3).min { abs(spread($0) - sigma * sigma) < abs(spread($1) - sigma * sigma) } ?? 0
        let boxes = (0..<3).map { $0 < wider ? narrow + 2 : narrow }
        if narrow >= 3 {
            var src = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                    rowBytes: ctx.bytesPerRow)
            let scratch = UnsafeMutableRawPointer.allocate(byteCount: ctx.bytesPerRow * h, alignment: 64)
            defer { scratch.deallocate() }
            var tmp = vImage_Buffer(data: scratch, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                    rowBytes: ctx.bytesPerRow)
            // What lies beyond the margin is nothing, not more of the edge.
            var clear: [UInt8] = [0, 0, 0, 0]
            let flags = vImage_Flags(kvImageBackgroundColorFill)
            vImageBoxConvolve_ARGB8888(&src, &tmp, nil, 0, 0, boxes[0], boxes[0], &clear, flags)
            vImageBoxConvolve_ARGB8888(&tmp, &src, nil, 0, 0, boxes[1], boxes[1], &clear, flags)
            vImageBoxConvolve_ARGB8888(&src, &tmp, nil, 0, 0, boxes[2], boxes[2], &clear, flags)
            memcpy(data, scratch, ctx.bytesPerRow * h)
        }
        return ctx.makeImage()?.cropping(to: CGRect(x: margin, y: margin, width: iw, height: ih))
    }

    // MARK: Colour

    /// The colour of each stop with the lap `phase` of the way round.
    ///
    /// A conic gradient's stops sit at even angles — here, of the layer's own
    /// proportions — and an even turn of them would race the colour along
    /// some stretches of the rim and crawl along others. So each stop is
    /// asked instead where its ray meets the rim, how far round that is, and
    /// which colour belongs there now: the colour moves at one steady pace
    /// along the rim itself. Clockwise, the way the flowing line runs.
    private func stopColours(phase: Double, _ s: RimSettings) -> [CGColor] {
        let cycle = s.cycle
        guard cycle.count > 1 else { return [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1)] }
        let hw = Double(bounds.width / 2 - s.inset), hh = Double(bounds.height / 2 - s.inset)
        let perimeter = 4 * (hw + hh)
        let n = Double(cycle.count)
        return (0...Self.stops).map { k in
            let theta = Double(k) / Double(Self.stops) * 2 * .pi   // clockwise from 3 o'clock
            // The layer's angles are of its own shape: this far round is
            // this direction on screen.
            let dx = cos(theta) * Double(bounds.width / 2), dy = sin(theta) * Double(bounds.height / 2)
            let tx = abs(dx) > 1e-9 ? hw / abs(dx) : .infinity
            let ty = abs(dy) > 1e-9 ? hh / abs(dy) : .infinity
            let x = dx * min(tx, ty), y = dy * min(tx, ty)
            // Distance round the rim, clockwise from the middle of the right side.
            let along: Double
            if tx <= ty {
                along = dx > 0 ? (y >= 0 ? y : 3 * hh + 4 * hw + (y + hh))
                               : hh + 2 * hw + (hh - y)
            } else {
                along = dy > 0 ? hh + (hw - x) : 3 * hh + 2 * hw + (x + hw)
            }
            var u = (along / perimeter - phase) * n
            u -= (u / n).rounded(.down) * n
            let i = Int(u) % cycle.count, j = (i + 1) % cycle.count, f = u - Double(Int(u))
            let a = cycle[i], b = cycle[j]
            // sRGB, which is what the palette's numbers are. The plain
            // red-green-blue initialiser means a different, brighter space.
            return CGColor(srgbRed: a.r + (b.r - a.r) * f, green: a.g + (b.g - a.g) * f,
                           blue: a.b + (b.b - a.b) * f, alpha: 1)
        }
    }

    /// Paints the stops for this moment, carrying the colour on from where
    /// it last was.
    private func colour() {
        guard let s = settings, !isHidden else { return }
        let now = CACurrentMediaTime()
        // A lap every 28s while playing, slowed right down when idle. Nothing
        // the music does changes it. Over a longer gap than the timer ever
        // leaves, the light was stopped — hidden, or not animating — and the
        // colour stood still with it.
        let period: Double = s.drift ? 60 : 28
        let gap = now - colouredAt
        if Self.debugMode != 1, gap < 1 { phase += gap / period }
        phase -= phase.rounded(.down)
        colouredAt = now
        let colours = stopColours(phase: phase, s)
        withoutActions { gradient.colors = colours }
    }

    // MARK: Strength

    /// How bright each pass is for a given strength of light.
    private static func opacities(strength: Double, swell: Double = 1) -> (wide: Float, near: Float, line: Float) {
        (Float(min(0.45 * strength * swell, 1)), Float(0.55 * strength),
         Float(min(1, 0.75 + 0.25 * strength)))
    }

    /// Sets how bright the light is now: steady when nothing plays; riding
    /// the bass when it is following the audio; otherwise a breath, or a
    /// struck note on each beat.
    private func brighten(_ bands: AudioBands?) {
        guard let s = settings else { return }
        let o: (wide: Float, near: Float, line: Float)
        if s.drift {
            o = Self.opacities(strength: 0.4 * 0.7)
        } else if s.hearing {
            // Bass carries the brightness. A floor keeps the line alive
            // through quiet passages instead of blinking out between hits.
            let bass = bands?.bass ?? 0
            let depth = min(max(s.pulse, 0.25), 1)
            o = Self.opacities(strength: s.glow * ((1 - depth) * 0.55 + depth * (0.25 + 0.95 * bass)),
                               swell: 1 + 0.7 * bass)
        } else {
            let depth = min(max(s.pulse, 0), 1)
            // The wall clock, so every rim in the app is on the same beat.
            let t = Date.timeIntervalSinceReferenceDate
            let shape: Double
            if !s.animating {
                shape = 0.5
            } else if let period = s.beatPeriod, period > 0.15 {
                // A struck note rather than a sine: a fast rise on the beat
                // and a decay over the rest of it.
                shape = pow(1 - t.truncatingRemainder(dividingBy: period) / period, 2.2)
            } else {
                // A 7.4s breath.
                shape = 0.5 + 0.5 * sin(t * 2 * .pi / 7.4)
            }
            o = Self.opacities(strength: s.glow * ((1 - depth) + depth * shape))
        }
        // Too small a change to see is not worth a frame.
        guard abs(o.wide - shown.wide) > 0.003 || abs(o.near - shown.near) > 0.003
                || abs(o.line - shown.line) > 0.003 else { return }
        shown = o
        withoutActions {
            wideMask.opacity = o.wide
            nearMask.opacity = o.near
            lineMask.opacity = o.line
        }
    }

    /// A hit sends a bright comet a third of the way round the rim from the
    /// top, fading as it travels.
    private func comet() {
        func run(_ key: String, _ from: Double, _ to: Double) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            return a
        }
        for (l, peak) in [(flare, 0.9), (core, 1.0)] {
            let g = CAAnimationGroup()
            g.animations = [run("strokeEnd", 0.02, 0.35), run("strokeStart", 0, 0.29),
                            run("opacity", peak, 0)]
            g.duration = 0.6
            g.timingFunction = CAMediaTimingFunction(name: .linear)
            l.add(g, forKey: "comet")
        }
    }

    /// Debug (PRISM_EVAL): 1 holds the colours still, 2 hides the glows,
    /// 3 hides the line, 4 hides everything.
    nonisolated(unsafe) static var debugMode = 0
    var debugState: String {
        let c = (gradient.colors as? [CGColor]) ?? []
        func rgb(_ c: CGColor?) -> String { (c?.components ?? []).prefix(3).map { String(format: "%.2f", $0) }.joined(separator: ",") }
        return "rim \(Int(bounds.width))x\(Int(bounds.height)) hidden \(isHidden) stops \(c.count) "
            + "first \(rgb(c.first)) quarter \(rgb(c.count > 16 ? c[16] : nil)) half \(rgb(c.count > 32 ? c[32] : nil)) "
            + "opacities \(wideMask.opacity) \(nearMask.opacity) \(lineMask.opacity) "
            + "gradient bounds \(Int(gradient.bounds.width))x\(Int(gradient.bounds.height)) frame \(Int(gradient.frame.width))x\(Int(gradient.frame.height)) "
            + "cycle \(settings?.cycle.count ?? -1) drift \(settings?.drift ?? false) animating \(settings?.animating ?? false)"
    }
    func debugRefresh() {
        withoutActions {
            wideMask.isHidden = Self.debugMode == 2 || Self.debugMode == 4
            nearMask.isHidden = wideMask.isHidden
            lineMask.isHidden = Self.debugMode == 3 || Self.debugMode == 4
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
#endif
