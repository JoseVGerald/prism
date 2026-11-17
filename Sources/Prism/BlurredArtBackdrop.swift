#if canImport(AppKit)
import SwiftUI
import AppKit
import CoreImage
import QuartzCore

/// The cover art as a slowly drifting wash of colour behind locked-mode lyrics.
///
/// Built to stay out of the trap that cost the equalizer a quarter of the CPU:
///
/// * The blur is done **once per artwork**, on a 256px copy, and cached. A
///   full-screen `.blur` in SwiftUI would recompute a gaussian every frame.
/// * The drift is a `CABasicAnimation` on a plain layer, not a SwiftUI
///   animation. SwiftUI's `repeatForever` still ticks on the main thread every
///   frame; a Core Animation transform runs on the render server and costs the
///   app nothing once it has been added.
struct BlurredArtBackdrop: NSViewRepresentable {
    let url: String?
    /// Whether the wash drifts. Still while nothing plays.
    var moving = true

    func makeNSView(context: Context) -> DriftView { DriftView() }

    func updateNSView(_ view: DriftView, context: Context) {
        view.show(url)
        view.moving = moving
    }

    final class DriftView: NSView {
        private let image = CALayer()
        private var shown: String?
        private var loading: Task<Void, Never>?
        private var timer: Timer?
        private var occlusion: NSObjectProtocol?
        /// Where in its 52-second there-and-back the drift has got to.
        private var drifted = 0.0
        private var steppedAt: CFTimeInterval = 0

        var moving = true { didSet { if moving != oldValue { retime() } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
            image.contentsGravity = .resizeAspectFill
            image.opacity = 0
            image.actions = ["transform": NSNull()]
            layer?.addSublayer(image)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            // Oversized so the drift never reveals an edge.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            image.transform = CATransform3DIdentity
            image.frame = bounds.insetBy(dx: -bounds.width * 0.18, dy: -bounds.height * 0.18)
            CATransaction.commit()
            step(advance: false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
            occlusion = nil
            if let window {
                occlusion = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.retime() }
                }
            }
            retime()
        }

        func show(_ url: String?) {
            guard url != shown else { return }
            shown = url
            loading?.cancel()
            loading = Task { @MainActor [weak self] in
                let blurred = await BlurCache.shared.image(for: url)
                guard let self, !Task.isCancelled, self.shown == url else { return }
                self.present(blurred)
            }
        }

        private func present(_ cg: CGImage?) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = image.presentation()?.opacity ?? image.opacity
            fade.toValue = cg == nil ? 0 : 1
            fade.duration = 0.9
            image.contents = cg
            image.opacity = cg == nil ? 0 : 1
            image.add(fade, forKey: "fade")
            retime()
        }

        /// The drift is stepped ten times a second rather than run as an
        /// animation. It moves about a point a second, so the steps cannot
        /// be seen — but an animation is drawn at the display's rate, and in
        /// a display-sized window that is sixty frames a second composited
        /// for a picture that has barely moved. Stopped while nothing plays,
        /// or with the window covered.
        private func retime() {
            let wanted = moving && image.contents != nil
                && window?.occlusionState.contains(.visible) == true
            guard wanted else {
                timer?.invalidate()
                timer = nil
                return
            }
            guard timer == nil else { return }
            steppedAt = CACurrentMediaTime()
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step(advance: true) }
            }
            t.tolerance = 0.02
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        private func step(advance: Bool) {
            let now = CACurrentMediaTime()
            if advance { drifted += min(now - steppedAt, 0.5) }
            steppedAt = now
            // Out for 26 seconds and back for 26, easing at each end.
            let p = drifted.truncatingRemainder(dividingBy: 52) / 26
            let u = p <= 1 ? p : 2 - p
            let eased = u * u * (3 - 2 * u)
            let scale = 1 + 0.12 * eased
            let slide = (-0.04 + 0.08 * eased) * bounds.width
            image.transform = CATransform3DTranslate(CATransform3DMakeScale(scale, scale, 1),
                                                     slide / scale, 0, 0)
        }
    }
}

/// Blurred, darkened copies of artwork, made once each.
actor BlurCache {
    static let shared = BlurCache()

    private var store: [String: CGImage] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])

    func image(for url: String?) async -> CGImage? {
        guard let url, let parsed = URL(string: url) else { return nil }
        if let hit = store[url] { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: parsed),
              let source = CIImage(data: data) else { return nil }

        // Work on a small copy: at 256px a 22px blur already reads as pure
        // colour, and it is a small fraction of the cost of blurring full size.
        let scale = 256 / max(source.extent.width, source.extent.height, 1)
        let small = source.transformed(by: .init(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 22)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35,
                kCIInputBrightnessKey: -0.18,
                kCIInputContrastKey: 1.05
            ])
            .cropped(to: small.extent)

        guard let cg = context.createCGImage(blurred, from: blurred.extent) else { return nil }
        store[url] = cg
        return cg
    }
}
#endif
