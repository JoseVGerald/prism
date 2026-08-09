import SwiftUI
import AppKit

/// A borderless always-on-top panel that never steals focus.
///
/// Both the mini player and the notch island are these. `canBecomeKey` stays
/// false so clicking a control does not pull you out of whatever you were
/// typing in, and `.canJoinAllSpaces` keeps them with you across desktops.
final class FloatingPanel: NSPanel {
    init(size: NSSize, level: NSWindow.Level, movable: Bool) {
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
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
