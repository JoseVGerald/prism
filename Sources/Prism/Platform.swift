import SwiftUI
import WebKit
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The handful of places where macOS and iOS genuinely differ.
///
/// Prism is one codebase for both. Almost all of it — the engine, the JS
/// bridge, the queue, history, stats, AutoMix — is platform-neutral already,
/// because it talks to a webview and to plain Swift types. What is *not*
/// neutral is a short list: the image type, how a webview is embedded, how a
/// blur is drawn, and how a file is picked. Everything below exists so those
/// differences live in one file instead of being smeared through the app.
///
/// The rule followed here: shim the *type*, not the feature. Where iOS simply
/// has no counterpart — the notch panel, CoreAudio output switching, system
/// audio capture — the feature is left out of the iOS build entirely rather
/// than faked with something that looks similar and behaves differently.

#if canImport(AppKit)
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#else
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#endif

extension PlatformImage {
    /// The bitmap behind the image. `NSImage` can be backed by anything and has
    /// to be asked for one; `UIImage` usually already is one.
    var prismCGImage: CGImage? {
        #if canImport(AppKit)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}

extension Color {
    /// sRGB components, 0…1.
    ///
    /// `NSColor.usingColorSpace(.sRGB)` has no UIKit equivalent, and
    /// `UIColor.getRed` returns false for greyscale colours rather than
    /// filling in the values, so both cases are handled explicitly instead of
    /// being allowed to fall through to black.
    var prismRGBA: (r: Double, g: Double, b: Double, a: Double) {
        let platform = PlatformColor(self)
        #if canImport(AppKit)
        let c = platform.usingColorSpace(.sRGB) ?? .white
        return (Double(c.redComponent), Double(c.greenComponent),
                Double(c.blueComponent), Double(c.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if platform.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b), Double(a))
        }
        var white: CGFloat = 0
        if platform.getWhite(&white, alpha: &a) {
            return (Double(white), Double(white), Double(white), Double(a))
        }
        return (1, 1, 1, 1)
        #endif
    }
}

/// Opens a URL outside the app.
enum PlatformOpener {
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

#if canImport(AppKit)
/// Reports whether the window this sits in is actually on screen.
///
/// `NSApplication.occlusionState` cannot answer this for Prism: the notch
/// island is a panel of its own and is always visible, so the app is always
/// "visible" no matter what the main window is doing. The question has to be
/// asked of the window.
///
/// It exists for the equalizer, which is a 20fps canvas and the most expensive
/// thing Prism draws. With the window buried behind a browser it was still
/// painting every frame, at full cost, for nobody.
struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ProbeView)?.onChange = onChange
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { onChange?(false); return }
            report()
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
        }

        private func report() {
            // Miniaturised windows do not always clear the occlusion bit, so
            // both are checked.
            let visible = (window?.occlusionState.contains(.visible) ?? false)
                && !(window?.isMiniaturized ?? false)
            onChange?(visible)
        }

        // No deinit teardown: the observer is dropped when the view is, and
        // reaching a non-Sendable token from a nonisolated deinit does not
        // compile. Re-registration already removes the previous one.
    }
}
#endif

/// Embeds the engine's webview in SwiftUI.
///
/// `WKWebView` is the same class on both platforms and every command Prism
/// sends it goes through the injected bridge, so only the representable
/// protocol differs.
#if canImport(AppKit)
struct EngineWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
/// Holds the engine's webview, and disarms the touch-delay path that crashed
/// the app the first time anyone tapped it.
///
/// **The crash.** Any touch reaching the webview killed the process:
///
///     *** Terminating app due to uncaught exception 'NSInvalidArgumentException',
///     reason: '*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil'
///         -[UIGestureRecognizer _delayTouchesForEvent:inPhase:]
///         -[UIGestureRecognizer _delayTouchesForEventIfNeeded:]
///         -[UIGestureEnvironment _updateForEvent:window:]
///
/// UIKit's gesture machinery finding nil where a delayed touch should be. Not
/// the app's own state — it survived being reduced to the bare webview with no
/// siblings, no chrome and no modifiers, and still died on the first tap.
///
/// Four plausible causes were tried and cleared, which is worth recording so
/// nobody spends the time again: the `scaleEffect` used for video bleed, the
/// surrounding view tree, hosting the shared `WKWebView` directly out of
/// `makeUIView` instead of inside a container, and the missing
/// `UIApplicationSceneManifest`. None of them.
///
/// **The fix** is to leave the crashing code path unused. `delaysTouchesBegan`
/// exists to let a gesture win a race against the view under it, and there is
/// no such race here: the webview is interactive in exactly one situation,
/// signing in, where nothing competes for the touch.
///
/// **Why it took this long to see.** The webview is hit-testable only during
/// sign-in, and until sign-in started loading a real form the page behind that
/// overlay was a music video — nothing anyone would tap. The bug is as old as
/// the iOS port; giving it a text field is what exposed it.
///
/// The container is also worth keeping on its own merits: SwiftUI gets a view
/// it owns, and the shared webview is re-parented at most once, on creation,
/// so the media suspension this project is built around avoiding never
/// happens.
final class EngineWebViewContainer: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
    }

    /// Stop every recognizer in reach from *delaying* touches.
    ///
    /// The crash is inside `-[UIGestureRecognizer _delayTouchesForEvent:inPhase:]`,
    /// so the cheapest way past it is to leave that code path unused. Delaying
    /// touches buys nothing here: the webview is only ever interactive on the
    /// sign-in page, where there is no competing gesture worth disambiguating.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var view: UIView? = self
        while let v = view {
            for g in v.gestureRecognizers ?? [] {
                g.delaysTouchesBegan = false
                g.delaysTouchesEnded = false
            }
            view = v.superview
        }
        for sub in allSubviews(of: self) {
            for g in sub.gestureRecognizers ?? [] {
                g.delaysTouchesBegan = false
                g.delaysTouchesEnded = false
            }
        }
    }

    private func allSubviews(of root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap { allSubviews(of: $0) }
    }
}

struct EngineWebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> EngineWebViewContainer {
        let container = EngineWebViewContainer()
        container.addSubview(webView)
        webView.frame = container.bounds
        return container
    }

    func updateUIView(_ view: EngineWebViewContainer, context: Context) {
        // Only if SwiftUI has built a new container; moving it every update
        // would be the re-parenting this whole arrangement exists to avoid.
        if webView.superview !== view {
            view.addSubview(webView)
            webView.frame = view.bounds
        }
    }
}
#endif

extension WKWebView {
    /// Makes the webview transparent so the app's own background shows through.
    ///
    /// macOS uses a private `drawsBackground` flag; iOS has real properties.
    /// Setting the wrong one is silently ignored, which is exactly the kind of
    /// no-op this project has been bitten by before, so both are spelled out.
    func prismMakeTransparent() {
        #if canImport(AppKit)
        setValue(false, forKey: "drawsBackground")
        #else
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        #endif
    }

    /// Keeps audio playing when the app is not in front.
    ///
    /// On iOS this is the difference between a music app and a toy: without
    /// `allowsInlineMediaPlayback` the page is handed to the fullscreen native
    /// player and the bridge loses control of it, and without the audio
    /// session configured in `PrismApp`, playback stops the moment the screen
    /// locks.
    static func prismConfiguration(_ config: WKWebViewConfiguration) {
        config.mediaTypesRequiringUserActionForPlayback = []
        #if canImport(UIKit)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        #endif
    }
}
