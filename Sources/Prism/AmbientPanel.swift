#if canImport(AppKit)
import SwiftUI
import AppKit

/// The full-screen ambient surface (frame 1d).
///
/// Deliberately *not* the Lock Screen. macOS only lets a screen-saver bundle
/// draw there, and a saver is a separate sandboxed process that would need an
/// App Group — which needs a paid developer account — before it could be told
/// what is playing. Inside the app none of that applies: the palette, title,
/// artist and clock are all already here. What this cannot do is survive the
/// Mac actually locking, and it secures nothing; it is a cover, not a lock.
///
/// Because it must dismiss on *any key*, this panel can become key — the one
/// place `FloatingPanel`'s rule is wrong. The alternative is a global event
/// monitor, which would mean asking for Accessibility permission just to close
/// a screen saver.
@MainActor
final class AmbientPanelController {

    private var panel: AmbientPanel?
    private let model: AppModel
    private var screenObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard self.panel != nil else { return }
                    self.reposition()
                }
            }
    }

    var isPresenting: Bool { panel?.isVisible ?? false }

    func toggle() { isPresenting ? dismiss() : present() }

    /// Main display only, by choice: the other monitors keep whatever was on
    /// them. One panel, so there is exactly one thing to dismiss.
    private var targetScreen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    func present() {
        guard !isPresenting, let screen = targetScreen else { return }

        let p = AmbientPanel(contentRect: screen.frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.onDismiss = { [weak self] in self?.dismiss() }
        p.isOpaque = true
        p.backgroundColor = .black
        p.hasShadow = false
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        // Above the menu bar, which it covers along with everything else.
        p.level = .init(Int(CGWindowLevelForKey(.maximumWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(
            rootView: AmbientSurface(model: model, screenCorner: cornerRadius(of: screen)))
        p.setFrame(screen.frame, display: true)

        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.ambient.presenting = true
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        model.ambient.presenting = false
    }

    private func reposition() {
        guard let panel, let screen = targetScreen else { return }
        panel.setFrame(screen.frame, display: true)
    }

    /// The display's own bezel radius where macOS reports one, so the line
    /// follows the corners of the screen rather than cutting across them.
    private func cornerRadius(of screen: NSScreen) -> CGFloat {
        // Notched Macs report a real radius; everything else gets a sane one.
        screen.safeAreaInsets.top > 0 ? 12 : 6
    }
}

/// The panel itself. Key-capable, and any key or click closes it.
final class AmbientPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Take the frame that was asked for, exactly.
    ///
    /// `NSWindow` otherwise shrinks a window to keep it clear of the menu bar
    /// and the Dock. Measured: asking for the screen's full 1470x956 produced a
    /// 1442x938 panel inset by (14, 9), leaving a hairline of desktop around a
    /// surface whose whole job is to cover the display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func keyDown(with event: NSEvent) { onDismiss?() }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }

    /// Escape and ⌘. arrive here rather than as `keyDown`. Returning true keeps
    /// the beep away; either way the surface goes.
    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    /// Never trap the user. Any command the app would normally take — including
    /// ⌘Q — closes this first and is then handled as usual.
    ///
    /// The one exception is the shortcut that opened it. Letting ⌘⇧L through
    /// dismissed the surface and then immediately hit the menu item, which saw
    /// nothing presented and put it straight back up — the toggle looked dead.
    /// Consuming it here makes the same key close what it opened.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isAmbientShortcut = event.charactersIgnoringModifiers?.lowercased() == "l"
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .isSuperset(of: [.command, .shift])
        onDismiss?()
        return isAmbientShortcut
    }
}
#endif
