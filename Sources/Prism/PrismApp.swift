import SwiftUI
import AppKit

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .background(WindowConfigurator())
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
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
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
}
