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

    private let trail = CAReplicatorLayer()
    /// One point of the tail; the replicator draws the rest from it.
    private let bead = CALayer()
    /// The head's glow, which swells on the beat and on a hit.
    private let bloom = CALayer()

    private var settings: FlowSettings?
    /// The rim, sampled evenly by length.
    private var samples: [CGPoint] = []
    /// The beat heard in the audio, on the media clock.
    private var heard: (period: Double, anchor: CFTimeInterval)?
    private var lastOnset: Date?
    private var built: Built?

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

    static let beatsPerLap = 8
    static let sampleCount = 480
    static let beadCount = 40

    override init() {
        super.init()
        addSublayer(trail)
        trail.addSublayer(bead)
        addSublayer(bloom)
        trail.instanceCount = Self.beadCount
        trail.instanceAlphaOffset = -0.95 / Float(Self.beadCount)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Inputs

    func resize(to bounds: CGRect) {
        guard frame != bounds || samples.isEmpty else { return }
        withoutActions {
            frame = bounds
            trail.frame = bounds
        }
        resample()
        rebuild()
    }

    func apply(_ new: FlowSettings) {
        let old = settings
        settings = new
        guard old != new else { return }
        let recolour = old.map { $0.accent != new.accent || $0.thickness != new.thickness } ?? true
        if recolour { restyle() }
        if old?.inset != new.inset || old?.corner != new.corner { resample() }
        rebuild()
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
                // How far the heard beat sits from the grid we are drawing.
                let k = ((b.anchor - a.anchor) / a.period).rounded()
                return abs(b.anchor - (a.anchor + k * a.period)) > 0.03
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

    private func resample() {
        guard let s = settings, bounds.width > s.inset * 2 + 4,
              bounds.height > s.inset * 2 + 4 else { samples = []; return }
        let rect = bounds.insetBy(dx: s.inset, dy: s.inset)
        let path = Path(roundedRect: rect, cornerRadius: s.corner, style: .continuous)
        samples = (0..<Self.sampleCount).map { i in
            let f = Double(i) / Double(Self.sampleCount)
            return f == 0 ? (path.trimmedPath(from: 0, to: 0.0001).currentPoint ?? .zero)
                          : (path.trimmedPath(from: 0, to: f).currentPoint ?? .zero)
        }
    }

    private func restyle() {
        guard let s = settings else { return }
        let scale = contentsScale
        withoutActions {
            let beadSize = s.thickness * 7
            bead.bounds = CGRect(x: 0, y: 0, width: beadSize, height: beadSize)
            bead.contents = Self.glow(diameter: beadSize, scale: scale,
                                      core: (1, 1, 1), edge: (1, 1, 1), coreStop: 0.22)
            bead.contentsScale = scale
            let bloomSize = s.thickness * 16
            bloom.bounds = CGRect(x: 0, y: 0, width: bloomSize, height: bloomSize)
            bloom.contents = Self.glow(diameter: bloomSize, scale: scale, core: (1, 1, 1),
                                       edge: (s.accent.r, s.accent.g, s.accent.b), coreStop: 0.1)
            bloom.contentsScale = scale
            // Head white, tail the artwork's accent: each copy's colour steps
            // from white towards it, multiplying the white bead.
            let n = Float(Self.beadCount)
            trail.instanceColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            trail.instanceRedOffset = Float(s.accent.r - 1) / n * 1.4
            trail.instanceGreenOffset = Float(s.accent.g - 1) / n * 1.4
            trail.instanceBlueOffset = Float(s.accent.b - 1) / n * 1.4
        }
    }

    private func rebuild() {
        guard let s = settings, !samples.isEmpty else { return }
        let now = CACurrentMediaTime()
        guard s.animating else {
            // Hold the head where it is; the next build carries on from there.
            if let b = built {
                built = Built(start: b.head(at: now), begin: now, lap: b.lap, surge: 0)
            }
            bead.removeAllAnimations()
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
        // Whole laps earlier: the same motion from now on, but the tail's
        // delayed copies also land inside the animation instead of before it.
        begin -= 2 * lap

        built = Built(start: start, begin: begin, lap: lap, surge: surge)

        withoutActions {
            opacity = s.playing ? 1 : 0.4
            bead.position = samples[Int(start * Double(samples.count)) % samples.count]
            bloom.position = bead.position
            // Trail length: an eighth of a lap behind the head.
            trail.instanceDelay = lap * 0.12 / Double(Self.beadCount)
        }

        let move = positionAnimation(start: start, surge: surge, lap: lap, begin: begin)
        bead.add(move, forKey: "flow")
        bloom.add(move, forKey: "flow")
        bloom.add(pulseAnimation(beat: folded?.period, depth: s.depth, begin: begin),
                  forKey: "pulse")
    }

    /// The head's path round the rim, one lap. With a beat, each eighth of
    /// the lap is one beat whose keyframes bunch up early — the surge.
    private func positionAnimation(start: Double, surge: Double, lap: Double,
                                   begin: CFTimeInterval) -> CAKeyframeAnimation {
        let n = samples.count
        var values: [NSValue] = []
        var times: [NSNumber] = []
        values.reserveCapacity(n + 1)
        times.reserveCapacity(n + 1)
        let offset = Int((start * Double(n)).rounded())
        for j in 0...n {
            let p = samples[(offset + j) % n]
            #if canImport(AppKit)
            values.append(NSValue(point: p))
            #else
            values.append(NSValue(cgPoint: p))
            #endif
            times.append(NSNumber(value: Self.time(atDistance: Double(j) / Double(n), surge: surge)))
        }
        let a = CAKeyframeAnimation(keyPath: "position")
        a.values = values
        a.keyTimes = times
        a.calculationMode = .linear
        a.duration = lap
        a.repeatCount = .infinity
        a.beginTime = bead.convertTime(begin, from: nil)
        a.isRemovedOnCompletion = false
        return a
    }

    /// The bloom swells on each beat and decays over it — a struck note. With
    /// no beat, it breathes.
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
        group.beginTime = bloom.convertTime(beat == nil ? CACurrentMediaTime() : begin, from: nil)
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

    /// How far round a beat the head has got, `τ` of the way through it.
    ///
    /// Speed is `1 + surge·(env − 1/3.2)` with `env = (1 − τ)^2.2`, the same
    /// struck note as the ring's beat. That averages exactly 1 over a beat, so
    /// the average pace is the tempo's, and this is its integral.
    static func withinBeat(_ tau: Double, surge: Double) -> Double {
        tau + surge * ((1 - pow(1 - tau, 3.2)) / 3.2 - tau / 3.2)
    }

    /// Fraction of the lap covered after `f` of its time.
    static func distance(atTime f: Double, surge: Double) -> Double {
        guard surge > 0 else { return f }
        let beats = Double(beatsPerLap)
        let x = min(max(f, 0), 1) * beats
        let b = min(x.rounded(.down), beats - 1)
        return (b + withinBeat(x - b, surge: surge)) / beats
    }

    /// Fraction of the lap's time taken to cover `d` of it — the inverse, by
    /// bisection, since the integral has no closed-form inverse.
    static func time(atDistance d: Double, surge: Double) -> Double {
        guard surge > 0 else { return d }
        let beats = Double(beatsPerLap)
        let x = min(max(d, 0), 1) * beats
        let b = min(x.rounded(.down), beats - 1)
        let target = x - b
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if withinBeat(mid, surge: surge) < target { lo = mid } else { hi = mid }
        }
        return (b + (lo + hi) / 2) / beats
    }

    // MARK: Drawing

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// A round glow: solid colour at the centre falling off to nothing.
    static func glow(diameter: CGFloat, scale: CGFloat,
                     core: (Double, Double, Double), edge: (Double, Double, Double),
                     coreStop: CGFloat) -> CGImage? {
        let px = max(Int(diameter * scale), 4)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colours = [CGColor(red: core.0, green: core.1, blue: core.2, alpha: 1),
                       CGColor(red: edge.0, green: edge.1, blue: edge.2, alpha: 0.55),
                       CGColor(red: edge.0, green: edge.1, blue: edge.2, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colours, locations: [0, coreStop, 1])
        else { return nil }
        let c = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0,
                               endCenter: c, endRadius: CGFloat(px) / 2, options: [])
        return ctx.makeImage()
    }
}
