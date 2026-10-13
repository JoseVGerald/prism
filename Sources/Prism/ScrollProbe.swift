#if canImport(AppKit)
import AppKit
import QuartzCore

/// Debug only (PRISM_EVAL): scrolls the longest list in the window up and
/// down for a few seconds and counts the frames that came late.
///
/// What "scrolling is laggy" means, as a number that can be compared before
/// and after a change: every display refresh the list moves a fixed speed, and
/// a refresh that arrives more than half a frame late is a frame the user saw
/// stick.
@MainActor
final class ScrollProbe: NSObject {
    private let scrollView: NSScrollView
    private let seconds: Double
    private let speed: Double
    private let report: (String) -> Void
    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var direction = 1.0
    private var gaps: [Double] = []
    private var dropped = 0
    private static var running: ScrollProbe?

    private init(scrollView: NSScrollView, seconds: Double, speed: Double,
                 report: @escaping (String) -> Void) {
        self.scrollView = scrollView
        self.seconds = seconds
        self.speed = speed
        self.report = report
    }

    /// `front`: put the window on top for the run, without taking the
    /// keyboard, and back after. A covered window draws next to nothing, so
    /// a run behind other windows measures nothing.
    /// `pointer`: park the pointer over the list for the run, as it is when
    /// scrolling with a trackpad, so rows light and dim as they pass under
    /// it; and put it back after.
    static func run(seconds: Double = 6, speed: Double = 1800, front: Bool = false,
                    pointer: Bool = false, report: @escaping (String) -> Void) {
        guard running == nil else { return report("scroll probe: already running") }
        if front, let main = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            main.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated {
                    var restore: CGPoint?
                    if pointer, let list = longest() {
                        // Quartz's global space has its origin top-left of the main display.
                        let r = list.window!.convertToScreen(list.convert(list.bounds, to: nil))
                        let top = NSScreen.screens.first?.frame.maxY ?? 0
                        restore = CGEvent(source: nil)?.location
                        CGWarpMouseCursorPosition(CGPoint(x: r.midX, y: top - r.midY))
                        CGAssociateMouseAndMouseCursorPosition(1)
                    }
                    run(seconds: seconds, speed: speed, front: false) { line in
                        report(line)
                        guard line.contains("frames of") else { return }
                        main.orderBack(nil)
                        if let restore { CGWarpMouseCursorPosition(restore); CGAssociateMouseAndMouseCursorPosition(1) }
                    }
                }
            }
            return
        }
        guard let target = longest() else { return report("scroll probe: no long list on screen") }
        let probe = ScrollProbe(scrollView: target, seconds: seconds, speed: speed, report: report)
        running = probe
        probe.start()
    }

    /// The list being read: the scroll view with the most to scroll.
    private static func longest() -> NSScrollView? {
        let views = NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
            .flatMap { scrollViews(in: $0) }
        guard let target = views.max(by: { overflow($0) < overflow($1) }), overflow(target) > 200
        else { return nil }
        return target
    }

    private static func overflow(_ s: NSScrollView) -> CGFloat {
        (s.documentView?.frame.height ?? 0) - s.contentView.bounds.height
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let s = view as? NSScrollView, s.window != nil { found.append(s) }
        for sub in view.subviews { found += scrollViews(in: sub) }
        return found
    }

    private func start() {
        let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let window = scrollView.window
        let pointer = window.map { $0.mouseLocationOutsideOfEventStream } ?? .zero
        let overList = scrollView.convert(scrollView.bounds, to: nil).contains(pointer)
        report("scroll probe: \(type(of: scrollView)) content \(Int(scrollView.documentView?.frame.height ?? 0)) pt, "
               + "app active \(NSApp.isActive), window visible \(window?.occlusionState.contains(.visible) ?? false), "
               + "key \(window?.isKeyWindow ?? false), pointer over list \(overList)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if started == 0 { started = now; last = now; return }
        let dt = now - last
        last = now
        let frame = link.duration > 0 ? link.duration : 1.0 / 60
        gaps.append(dt)
        if dt > frame * 1.5 { dropped += Int((dt / frame).rounded()) - 1 }

        let clip = scrollView.contentView
        let maxY = max((scrollView.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
        var y = clip.bounds.origin.y + direction * speed * dt
        if y >= maxY { y = maxY; direction = -1 }
        if y <= 0 { y = 0; direction = 1 }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)

        if now - started >= seconds { finish(frame: frame) }
    }

    private func finish(frame: Double) {
        link?.invalidate()
        link = nil
        let sorted = gaps.sorted()
        let p = { (q: Double) in sorted.isEmpty ? 0 : sorted[min(Int(Double(sorted.count) * q), sorted.count - 1)] }
        let ms = { (s: Double) in String(format: "%.1f", s * 1000) }
        let expected = Int(seconds / frame)
        report("scroll probe: \(gaps.count) frames of ~\(expected), dropped \(dropped), "
               + "median \(ms(p(0.5))) ms, p95 \(ms(p(0.95))) ms, worst \(ms(sorted.last ?? 0)) ms, "
               + "late \(gaps.filter { $0 > frame * 1.5 }.count)")
        ScrollProbe.running = nil
    }
}
#endif
