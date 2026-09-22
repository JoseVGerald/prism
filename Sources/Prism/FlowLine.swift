import SwiftUI
import QuartzCore

/// The flowing line: a light that keeps running round the rim at the song's
/// tempo, surging on each beat and gliding between.
///
/// **Core Animation, not a SwiftUI timeline.** Drawn as a 60fps `Canvas` it
/// measured ~20% CPU — the canvas is rasterised on the CPU into a
/// window-sized bitmap every frame — and still ~11% with `drawingGroup()`,
/// from SwiftUI re-evaluating the view sixty times a second. Here the render
/// server moves it: one glowing bead follows a keyframed path round the rim,
/// a replicator makes the tail from delayed copies of it, and the beat's surge
/// is baked into the keyframe timing. Prism's own work is a rebuild when the
/// tempo changes and a 20 Hz glance at the audio for hits.
struct FlowLine: View {
    var accent: Color
    var playing: Bool
    var thickness: CGFloat
    var inset: CGFloat
    var corner: CGFloat
    var animating: Bool
    var pulse: Double
    /// Looked-up seconds per beat, used when the audio is not being heard.
    var tempo: Double?
    var audio: (any AudioBandsSource)?

    var body: some View {
        FlowLineHost(settings: .init(accent: accent.prismRGBA, playing: playing,
                                     thickness: thickness, inset: inset, corner: corner,
                                     animating: animating, depth: min(max(pulse, 0), 1),
                                     tempo: tempo),
                     audio: audio)
            .allowsHitTesting(false)
    }
}

/// Everything the layer is built from, compared to tell when to rebuild.
struct FlowSettings: Equatable {
    var accent: (r: Double, g: Double, b: Double, a: Double)
    var playing: Bool
    var thickness: CGFloat
    var inset: CGFloat
    var corner: CGFloat
    var animating: Bool
    var depth: Double
    var tempo: Double?

    static func == (l: FlowSettings, r: FlowSettings) -> Bool {
        l.accent == r.accent && l.playing == r.playing && l.thickness == r.thickness
            && l.inset == r.inset && l.corner == r.corner && l.animating == r.animating
            && l.depth == r.depth && l.tempo == r.tempo
    }
}

// MARK: - Hosting

#if canImport(AppKit)
private struct FlowLineHost: NSViewRepresentable {
    let settings: FlowSettings
    let audio: (any AudioBandsSource)?

    func makeNSView(context: Context) -> FlowHostView { FlowHostView() }
    func updateNSView(_ view: FlowHostView, context: Context) {
        view.audio = audio
        view.flow.apply(settings)
    }
}

final class FlowHostView: NSView {
    let flow = FlowLayer()
    weak var audio: (any AudioBandsSource)?
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(flow)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Top-left origin, so the light runs clockwise as it does on iOS.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        flow.contentsScale = window?.backingScaleFactor ?? 2
        flow.resize(to: bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flow.hear(self.audio?.bands)
            }
        }
    }
}
#else
private struct FlowLineHost: UIViewRepresentable {
    let settings: FlowSettings
    let audio: (any AudioBandsSource)?

    func makeUIView(context: Context) -> FlowHostView { FlowHostView() }
    func updateUIView(_ view: FlowHostView, context: Context) {
        view.flow.apply(settings)
    }
}

final class FlowHostView: UIView {
    let flow = FlowLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(flow)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        flow.contentsScale = window?.screen.scale ?? 3
        flow.resize(to: bounds)
    }
}
#endif

// MARK: - The layer

final class FlowLayer: CALayer {

    /// The tail: strokes of the same rim, each shorter, brighter and whiter
    /// than the one beneath, so together they taper into a comet. Real strokes
    /// rather than a replicated dot, which at full-screen speeds spread into
    /// visible beads.
    private var tails: [CAShapeLayer] = []
    /// The head's glow, which swells on the beat and on a hit.
    private let bloom = CALayer()

    private var settings: FlowSettings?
    private var rim: Rim?
    /// The beat heard in the audio, on the media clock.
    private var heard: (period: Double, anchor: CFTimeInterval)?
    private var lastOnset: Date?
    private var built: Built?

    /// (length as a share of the whole tail, width × thickness, whiteness, opacity),
    /// faintest and longest first.
    private static let strands: [(length: Double, width: CGFloat, white: Double, alpha: Float)] = [
        (1.00, 5.0, 0.00, 0.07),
        (0.90, 3.2, 0.00, 0.14),
        (0.76, 2.1, 0.10, 0.30),
        (0.60, 1.5, 0.25, 0.55),
        (0.42, 1.2, 0.50, 0.80),
        (0.24, 1.3, 0.80, 0.95),
        (0.08, 1.7, 1.00, 1.00),
    ]
    /// The whole tail, as a share of a lap.
    static let tailLength = 0.13
    static let beatsPerLap = 8
    static let keyframes = 480

    /// What the running animation was made from — enough to say where the
    /// head is at any moment, so a rebuild can carry on from there.
    private struct Built {
        var start: Double          // where on the loop the lap begins
        var begin: CFTimeInterval  // when a lap began, on a beat
        var lap: Double            // seconds
        var surge: Double          // 0 = even pace

        func head(at now: CFTimeInterval) -> Double {
            var f = ((now - begin) / lap).truncatingRemainder(dividingBy: 1)
            if f < 0 { f += 1 }
            return (start + FlowLayer.distance(atTime: f, surge: surge))
                .truncatingRemainder(dividingBy: 1)
        }
    }

    override init() {
        super.init()
        for s in Self.strands {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            l.opacity = s.alpha
            addSublayer(l)
            tails.append(l)
        }
        addSublayer(bloom)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Inputs

    func resize(to bounds: CGRect) {
        guard frame != bounds || rim == nil else { return }
        withoutActions { frame = bounds }
        reshape()
        rebuild()
    }

    func apply(_ new: FlowSettings) {
        let old = settings
        settings = new
        guard let old else { restyle(); reshape(); rebuild(); return }
        guard old != new else { return }
        // Colour alone changes every frame of a song change, as the palette
        // blends; that must only recolour, never rebuild the motion.
        if old.accent != new.accent || old.thickness != new.thickness { restyle() }
        let reshaped = old.inset != new.inset || old.corner != new.corner
        if reshaped { reshape() }
        if reshaped || old.playing != new.playing || old.depth != new.depth
            || old.tempo != new.tempo || old.animating != new.animating { rebuild() }
    }

    /// Called at 20 Hz with what the audio is doing. Rebuilds only when the
    /// heard beat has moved enough to see; flares the head on a hit.
    func hear(_ bands: AudioBands?) {
        let now = CACurrentMediaTime()
        var next: (period: Double, anchor: CFTimeInterval)?
        if let p = bands?.tempo, let at = bands?.beatAt, p > 0.15 {
            next = (p, now + at.timeIntervalSinceNow)
        }
        let changed: Bool = {
            switch (heard, next) {
            case (nil, nil): return false
            case let (a?, b?):
                guard abs(b.period / a.period - 1) < 0.01 else { return true }
                // How far the heard beat sits from the grid being drawn.
                let k = ((b.anchor - a.anchor) / a.period).rounded()
                return abs(b.anchor - (a.anchor + k * a.period)) > 0.04
            default: return true
            }
        }()
        if changed {
            heard = next
            rebuild()
        }

        if let at = bands?.onsetAt, at != lastOnset {
            lastOnset = at
            if at.timeIntervalSinceNow > -0.1, settings?.playing == true { flare() }
        }
    }

    // MARK: Building

    private func reshape() {
        guard let s = settings, bounds.width > s.inset * 2 + 4,
              bounds.height > s.inset * 2 + 4 else { rim = nil; return }
        let r = Rim(rect: bounds.insetBy(dx: s.inset, dy: s.inset), corner: s.corner)
        rim = r
        // Three laps end to end. The head's position within the middle
        // stretch never needs to wrap, so a tail crossing the seam where the
        // loop starts is still one unbroken stroke.
        let path = r.path(laps: 3)
        withoutActions {
            for l in tails {
                l.frame = bounds
                l.path = path
                l.contentsScale = contentsScale
            }
        }
    }

    private func restyle() {
        guard let s = settings else { return }
        let scale = contentsScale
        withoutActions {
            for (l, strand) in zip(tails, Self.strands) {
                let w = strand.white
                l.lineWidth = s.thickness * strand.width
                l.strokeColor = CGColor(red: s.accent.r + (1 - s.accent.r) * w,
                                        green: s.accent.g + (1 - s.accent.g) * w,
                                        blue: s.accent.b + (1 - s.accent.b) * w, alpha: 1)
            }
            let bloomSize = s.thickness * 16
            bloom.bounds = CGRect(x: 0, y: 0, width: bloomSize, height: bloomSize)
            bloom.contents = Self.glow(diameter: bloomSize, scale: scale,
                                       edge: (s.accent.r, s.accent.g, s.accent.b))
            bloom.contentsScale = scale
        }
    }

    private func rebuild() {
        guard let s = settings, let rim else { return }
        let now = CACurrentMediaTime()
        guard s.animating else {
            // Hold the head where it is; the next build carries on from there.
            if let b = built {
                built = Built(start: b.head(at: now), begin: now, lap: b.lap, surge: 0)
            }
            tails.forEach { $0.removeAllAnimations() }
            bloom.removeAllAnimations()
            return
        }
        let looked: (period: Double, anchor: CFTimeInterval)? =
            s.tempo.flatMap { $0 > 0.15 ? (period: $0, anchor: 0) : nil }
        let beat = s.playing ? (heard ?? looked) : nil
        let folded = beat.map { (period: Self.fold($0.period), anchor: $0.anchor) }

        let lap: Double, surge: Double
        var begin: CFTimeInterval
        if let folded {
            lap = folded.period * Double(Self.beatsPerLap)
            surge = 0.9 * s.depth
            begin = folded.anchor + ((now - folded.anchor) / folded.period).rounded(.down) * folded.period
        } else {
            lap = s.playing ? 10 : 30
            surge = 0
            begin = now
        }
        // Carry on from wherever the head is now, so a new tempo changes the
        // pace without the light jumping.
        let head = built?.head(at: now) ?? Double.random(in: 0..<1)
        var start = head - Self.distance(atTime: (now - begin) / lap, surge: surge)
        start = start.truncatingRemainder(dividingBy: 1)
        if start < 0 { start += 1 }
        // Whole laps earlier: the same motion from now on.
        begin -= 2 * lap
        built = Built(start: start, begin: begin, lap: lap, surge: surge)

        // One lap of keyframes, evenly spaced in time: where the head is, and
        // how long the tail is — it stretches with the surge, like a streak.
        let n = Self.keyframes
        var heads: [Double] = [], stretch: [Double] = [], points: [NSValue] = []
        heads.reserveCapacity(n + 1); stretch.reserveCapacity(n + 1); points.reserveCapacity(n + 1)
        for j in 0...n {
            let f = Double(j) / Double(n)
            let u = start + Self.distance(atTime: f, surge: surge)
            heads.append(u)
            let tau = (f * Double(Self.beatsPerLap)).truncatingRemainder(dividingBy: 1)
            stretch.append(1 + (surge > 0 ? 0.45 * s.depth * (Self.swell(tau) - 0.375) : 0))
            #if canImport(AppKit)
            points.append(NSValue(point: rim.point(at: u)))
            #else
            points.append(NSValue(cgPoint: rim.point(at: u)))
            #endif
        }

        let beginLocal = bloom.convertTime(begin, from: nil)
        func keyed(_ path: String, _ values: [Any]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values
            a.calculationMode = .linear
            a.duration = lap
            a.repeatCount = .infinity
            a.beginTime = beginLocal
            a.isRemovedOnCompletion = false
            return a
        }

        withoutActions {
            opacity = s.playing ? 1 : 0.4
            bloom.position = rim.point(at: start)
        }
        let ends = heads.map { NSNumber(value: (1 + $0) / 3) }
        for (l, strand) in zip(tails, Self.strands) {
            let length = Self.tailLength * strand.length
            let starts = zip(heads, stretch).map { NSNumber(value: (1 + $0 - length * $1) / 3) }
            l.add(keyed("strokeEnd", ends), forKey: "end")
            l.add(keyed("strokeStart", starts), forKey: "start")
        }
        bloom.add(keyed("position", points), forKey: "flow")
        bloom.add(pulseAnimation(beat: folded?.period, depth: s.depth, begin: beginLocal),
                  forKey: "pulse")
    }

    /// The bloom swells on each beat and decays over it — a struck note, sharp
    /// on purpose: this is what says "beat". With no beat, it breathes.
    private func pulseAnimation(beat: Double?, depth: Double,
                                begin: CFTimeInterval) -> CAAnimationGroup {
        let steps = 12
        let breathing = beat == nil
        func shape(_ t: Double) -> Double {
            breathing ? 0.5 - 0.5 * cos(t * 2 * Double.pi) : pow(1 - t, 2.2)
        }
        let d = max(depth, 0.15)
        let env: [Double] = (0...steps).map { shape(Double($0) / Double(steps)) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = env.map { e -> NSNumber in NSNumber(value: 0.45 + 0.55 * ((1 - d) + d * e)) }
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = env.map { e -> NSNumber in NSNumber(value: 0.8 + 0.7 * d * e) }
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = beat ?? 7.4
        group.repeatCount = .infinity
        group.beginTime = breathing ? bloom.convertTime(CACurrentMediaTime(), from: nil) : begin
        group.isRemovedOnCompletion = false
        return group
    }

    /// A hit: the head flashes bigger for a moment, on top of the beat pulse.
    private func flare() {
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.isAdditive = true
        a.fromValue = 0.9
        a.toValue = 0
        a.duration = 0.35
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bloom.add(a, forKey: "flare")
    }

    // MARK: Pace

    /// Folded into 80–160 BPM, so a ballad does not crawl and drum & bass
    /// does not smear.
    static func fold(_ period: Double) -> Double {
        var p = period
        for _ in 0..<4 where 60 / p < 80 { p /= 2 }
        for _ in 0..<4 where 60 / p >= 160 { p *= 2 }
        return p
    }

    /// Where in a beat the surge peaks: just after it lands.
    static let surgePeak = 0.06

    /// The surge's shape over one beat, `τ` 0…1: a smooth rise and fall with
    /// no corners anywhere, so the speed never jumps. Averages 0.375.
    static func swell(_ tau: Double) -> Double {
        let c = 0.5 + 0.5 * cos(2 * Double.pi * (tau - surgePeak))
        return c * c
    }

    /// How far round a beat the head has got, `τ` of the way through it.
    ///
    /// Speed is `1 + surge·(swell − 0.375)`, which averages exactly 1 over a
    /// beat — so the average pace is the tempo's — and this is its integral:
    /// `swell − 0.375 = ½cos x + ⅛cos 2x` with `x = 2π(τ − peak)`.
    static func withinBeat(_ tau: Double, surge: Double) -> Double {
        func w(_ t: Double) -> Double {
            let x = 2 * Double.pi * (t - surgePeak)
            return 0.5 * sin(x) / (2 * .pi) + 0.125 * sin(2 * x) / (4 * .pi)
        }
        return tau + surge * (w(tau) - w(0))
    }

    /// Fraction of the lap covered after `f` of its time.
    static func distance(atTime f: Double, surge: Double) -> Double {
        guard surge > 0 else { return f }
        let beats = Double(beatsPerLap)
        let x = min(max(f, 0), 1) * beats
        let b = min(x.rounded(.down), beats - 1)
        return (b + withinBeat(x - b, surge: surge)) / beats
    }

    // MARK: Drawing

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// A round glow: white at the centre, through the colour, to nothing.
    static func glow(diameter: CGFloat, scale: CGFloat,
                     edge: (Double, Double, Double)) -> CGImage? {
        let px = max(Int(diameter * scale), 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colours = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                       CGColor(red: edge.0, green: edge.1, blue: edge.2, alpha: 0.55),
                       CGColor(red: edge.0, green: edge.1, blue: edge.2, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colours,
                                        locations: [0, 0.1, 1]) else { return nil }
        let c = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0,
                               endCenter: c, endRadius: CGFloat(px) / 2, options: [])
        return ctx.makeImage()
    }
}

/// The rounded rectangle the light runs round, measured by length.
///
/// Built by hand rather than taken from `Path(roundedRect:)` so its direction
/// is known — clockwise on screen, the same way the ring's colour flows — and
/// so a point at any share of the way round is exact arithmetic instead of a
/// path trimmed from the start every time.
struct Rim {
    let rect: CGRect
    let corner: CGFloat

    init(rect: CGRect, corner: CGFloat) {
        self.rect = rect
        self.corner = max(0, min(corner, min(rect.width, rect.height) / 2))
    }

    private var straightX: CGFloat { rect.width - 2 * corner }
    private var straightY: CGFloat { rect.height - 2 * corner }
    private var quarter: CGFloat { .pi * corner / 2 }
    var length: CGFloat { 2 * straightX + 2 * straightY + 4 * quarter }

    /// Clockwise from the top edge's left end, in top-left-origin coordinates.
    func path(laps: Int) -> CGPath {
        let p = CGMutablePath()
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        p.move(to: CGPoint(x: x0 + corner, y: y0))
        for _ in 0..<laps {
            p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y1), radius: corner)
            p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x0, y: y1), radius: corner)
            p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y0), radius: corner)
            p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x1, y: y0), radius: corner)
            p.addLine(to: CGPoint(x: x0 + corner, y: y0))
        }
        return p
    }

    /// The point `u` of the way round (any real number; whole laps wrap).
    func point(at u: Double) -> CGPoint {
        var d = CGFloat(u - u.rounded(.down)) * length
        let (x0, y0, x1, y1, c) = (rect.minX, rect.minY, rect.maxX, rect.maxY, corner)
        func arc(_ cx: CGFloat, _ cy: CGFloat, from a: CGFloat, _ t: CGFloat) -> CGPoint {
            let angle = a + t * .pi / 2
            return CGPoint(x: cx + c * cos(angle), y: cy + c * sin(angle))
        }
        if d <= straightX { return CGPoint(x: x0 + c + d, y: y0) }; d -= straightX
        if d <= quarter { return arc(x1 - c, y0 + c, from: -.pi / 2, d / max(quarter, 1e-6)) }; d -= quarter
        if d <= straightY { return CGPoint(x: x1, y: y0 + c + d) }; d -= straightY
        if d <= quarter { return arc(x1 - c, y1 - c, from: 0, d / max(quarter, 1e-6)) }; d -= quarter
        if d <= straightX { return CGPoint(x: x1 - c - d, y: y1) }; d -= straightX
        if d <= quarter { return arc(x0 + c, y1 - c, from: .pi / 2, d / max(quarter, 1e-6)) }; d -= quarter
        if d <= straightY { return CGPoint(x: x0, y: y1 - c - d) }; d -= straightY
        return arc(x0 + c, y0 + c, from: .pi, min(d / max(quarter, 1e-6), 1))
    }
}
