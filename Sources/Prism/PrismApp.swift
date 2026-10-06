import SwiftUI
import AppKit

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .background(WindowConfigurator { model.windowControls = $0 })
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Undo is the queue's undo here — it is the only undoable thing in
            // the app, and the queue is where the accidents happen.
            CommandGroup(replacing: .undoRedo) {
                Button(undoTitle) { model.undoQueueEdit() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(model.engine.snapshot.undoLabel == nil)
            }
            CommandMenu("Playback") {
                Button(model.engine.snapshot.playback.isPlaying ? "Pause" : "Play") {
                    model.engine.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: .command)
                Button("Next") { model.engine.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { model.engine.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Shuffle Queue") { model.shuffleQueue() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Cycle Repeat") { model.engine.cycleRepeat() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Settings") {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button(model.ambient.presenting ? "Hide Ambient" : "Ambient") {
                    model.toggleAmbient()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("For You") { model.route = .forYou }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Now Playing") { model.route = .nowPlaying }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Search") { model.route = .search }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Library") { model.route = .library; model.loadLibraryIfNeeded() }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Listening") { model.route = .dashboard }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Downloads") { model.route = .downloads }
                    .keyboardShortcut("6", modifiers: .command)
                Divider()
                Button("New Quick Playlist") { model.makeQuickPlaylist() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button(model.lyricsMode ? "Hide Lyrics" : "Lyrics") { model.toggleLyrics() }
                    .keyboardShortcut("l", modifiers: .command)
                Button(model.compact ? "Exit Compact" : "Compact") { model.toggleCompact() }
                    .keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    private var undoTitle: String {
        if let label = model.engine.snapshot.undoLabel { return "Undo \(label)" }
        return "Undo"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DockIcon.install()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Reaches out of SwiftUI to make the window itself translucent, so the glass
/// panels have the desktop-grade backing they are designed against.
///
/// Also reports where the window's buttons are, so the rim can leave a gap
/// for them instead of running behind them, and keeps the full-screen title
/// bar clear: in full screen macOS slides its own title bar in over the top
/// of the content, with an opaque background `titlebarAppearsTransparent`
/// does not reach.
private struct WindowConfigurator: NSViewRepresentable {
    /// The close-to-zoom buttons, top-left origin, or nil when hidden.
    let onControls: @MainActor @Sendable (CGRect?) -> Void

    final class Coordinator {
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let report = onControls
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            report(Self.controls(in: window))
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                let entering = name == NSWindow.didEnterFullScreenNotification
                context.coordinator.observers.append(center.addObserver(
                    forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        report(Self.controls(in: window))
                        if entering {
                            // The full-screen title bar is built on entry, and
                            // again when it is first revealed; clear both.
                            Self.clearTitlebar(of: window)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                Self.clearTitlebar(of: window)
                            }
                        }
                    }
                })
            }
            Self.clearTitlebar(of: window)
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // Must stay false. When true, any drag that isn't on a native
            // control drags the window — so dragging the scrubber moved the
            // whole app instead of seeking. The transparent title bar strip
            // still drags the window normally.
            window.isMovableByWindowBackground = false
            // Clear + non-opaque is what lets the DesktopBlur behind the
            // content actually sample the desktop.
            window.backgroundColor = .clear
            window.isOpaque = false
            window.minSize = NSSize(width: 1000, height: 640)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Where the traffic lights are, in the content's top-left coordinates —
    /// nil in full screen, where they are hidden until the title bar slides in.
    @MainActor
    static func controls(in window: NSWindow) -> CGRect? {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let content = window.contentView else { return nil }
        let a = close.convert(close.bounds, to: nil)
        let b = zoom.convert(zoom.bounds, to: nil)
        let u = a.union(b)
        return CGRect(x: u.minX, y: content.frame.height - u.maxY, width: u.width, height: u.height)
    }

    /// Hides the material behind the title bar — the buttons stay. In full
    /// screen the buttons live in a separate title-bar window, which is found
    /// through them.
    @MainActor
    static func clearTitlebar(of window: NSWindow) {
        guard let button = window.standardWindowButton(.closeButton),
              let host = button.window else { return }
        if host !== window {
            host.isOpaque = false
            host.backgroundColor = .clear
        }
        var container: NSView? = button.superview
        while let v = container, !String(describing: type(of: v)).contains("TitlebarContainer") {
            container = v.superview
        }
        guard let root = container ?? button.superview?.superview else { return }
        func clear(_ view: NSView) {
            for sub in view.subviews {
                if sub is NSVisualEffectView || String(describing: type(of: sub)).contains("Background") {
                    sub.isHidden = true
                } else if !(sub is NSButton) {
                    sub.wantsLayer = true
                    sub.layer?.backgroundColor = NSColor.clear.cgColor
                    clear(sub)
                }
            }
        }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        clear(root)
    }
}
