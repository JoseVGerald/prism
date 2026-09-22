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

    func makeNSView(context: Context) -> DriftView { DriftView() }

    func updateNSView(_ view: DriftView, context: Context) {
        view.show(url)
    }

    final class DriftView: NSView {
        private let image = CALayer()
        private var shown: String?
        private var loading: Task<Void, Never>?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
            image.contentsGravity = .resizeAspectFill
            image.opacity = 0
            layer?.addSublayer(image)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            // Oversized so the drift never reveals an edge.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            image.frame = bounds.insetBy(dx: -bounds.width * 0.18, dy: -bounds.height * 0.18)
            CATransaction.commit()
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
            startDrift()
        }

        private func startDrift() {
            guard image.animation(forKey: "drift") == nil else { return }
            let zoom = CABasicAnimation(keyPath: "transform.scale")
            zoom.fromValue = 1.0
            zoom.toValue = 1.12
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = -bounds.width * 0.04
            slide.toValue = bounds.width * 0.04
            let group = CAAnimationGroup()
            group.animations = [zoom, slide]
            group.duration = 26
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            image.add(group, forKey: "drift")
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
