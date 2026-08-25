import SwiftUI
import AppKit

/// A borderless always-on-top panel that never steals focus.
///
/// Both the mini player and the notch island are these. `canBecomeKey` stays
/// false so clicking a control does not pull you out of whatever you were
/// typing in, and `.canJoinAllSpaces` keeps them with you across desktops.
final class FloatingPanel: NSPanel {
    /// Pass false for a panel that must outlive Cmd-H.
    ///
    /// Hiding the app orders every one of its windows out, on every space, and
    /// they only come back when the app is activated again. For the notch island
    /// that is indistinguishable from the feature being broken: hide Prism, spend
    /// the day in another app, and the island is simply gone. Measured — with the
    /// app hidden the island was on screen nowhere, which is exactly what a stale
    /// session looked like.
    init(size: NSSize, level: NSWindow.Level, movable: Bool, hidesWithApp: Bool = true) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = movable
        isReleasedWhenClosed = false
        canHide = hidesWithApp
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
