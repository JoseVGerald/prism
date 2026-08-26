import SwiftUI
import AppKit

/// The Dynamic-Island-style panel that lives in the MacBook's notch.
///
/// The panel is always the *expanded* size and mostly transparent; only the
/// drawn content changes between the collapsed chip and the open island. Sizing
/// the window on hover instead would make the hover target move out from under
/// the pointer and flap.
///
/// Geometry comes from the screen itself: `auxiliaryTopLeftArea` and
/// `auxiliaryTopRightArea` are the menu-bar strips either side of the notch, so
/// the gap between them is the notch, and `safeAreaInsets.top` is its height.
@MainActor
final class NotchController {

    private var panel: FloatingPanel?
    private let model: AppModel
    private var observers: [NSObjectProtocol] = []
    /// Set only by `close()`. Distinguishes "the user put it away" from "it went
    /// missing", so re-asserting visibility cannot resurrect a deliberate close.
    private var dismissed = false

    init(model: AppModel) {
        self.model = model

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.screensChanged() }
            })

        // The island is a panel with no owner on screen: nothing re-shows it if
        // it ever goes away, and once hidden it stayed hidden for the rest of
        // the session. Measured — a freshly launched island was on Chrome's
        // fullscreen space for 75 of 75 samples, while the same build after a
        // few hours was on it for 0 of 60, and by then *no* Prism window was on
        // any space at all. The panel's level and collection behaviour were
        // never the problem; staying ordered-in was.
        //
        // A display sleeping or being unplugged is enough to do it: the notched
        // screen momentarily disappears, `reposition` orders the panel out, and
        // if no further screen notification arrives it never comes back.
        //
        // So the island re-asserts itself whenever the desktop changes around
        // it. All three are rare and the work is a visibility check.
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { self.ensureVisible() }
                })
        }
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.ensureVisible() }
            })
    }

    /// Puts the island back if anything took it away.
    private func ensureVisible() {
        guard !dismissed, Self.notchedScreen != nil else { return }
        if panel == nil { open(); return }
        if panel?.isVisible != true { reposition() }
    }

    /// The display with the physical notch, whichever one that is.
    ///
    /// Not `NSScreen.main` — that is the screen holding the key window, so the
    /// moment Prism's window was dragged to an external monitor the island
    /// vanished: `available` went false and `open()` bailed. The notch is a
    /// property of the hardware, not of where the window happens to be, so the
    /// island stays in it and keeps working while you use the app elsewhere.
    static var notchedScreen: NSScreen? {
        NSScreen.screens.first { notchSize($0) != nil }
    }

    /// True on Macs that actually have a notch. Elsewhere the island would be a
    /// floating bar stuck under the menu bar, which is not what was asked for.
    static var available: Bool { notchedScreen != nil }

    var isOpen: Bool { panel?.isVisible ?? false }

    /// A display was added, removed or rearranged.
    ///
    /// `open()` is retried rather than only repositioning, because a session
    /// that started clamshelled built no panel at all — and without this the
    /// island would then stay missing until the app was restarted, even once
    /// the lid was open again.
    private func screensChanged() {
        guard !dismissed else { return }
        if panel == nil { open() } else { reposition() }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        dismissed = false
        guard let screen = Self.notchedScreen, let notch = Self.notchSize(screen) else { return }
        if panel != nil { reposition(); panel?.orderFrontRegardless(); return }

        let size = NSSize(width: NotchIslandView.width, height: NotchIslandView.height)
        // Above the menu bar, or the island would slide underneath it.
        // Outlives Cmd-H: the notch is a place on the hardware, not a window of
        // Prism's that should vanish because the app was hidden.
        let p = FloatingPanel(size: size, level: .init(Int(CGWindowLevelForKey(.mainMenuWindow)) + 3),
                              movable: false, hidesWithApp: false)
        p.contentView = NSHostingView(
            rootView: NotchIslandView(model: model, notch: notch))
        panel = p
        reposition()
        p.orderFrontRegardless()
    }

    func close() {
        dismissed = true
        panel?.orderOut(nil)
        panel = nil
    }

    private func reposition() {
        guard let panel else { return }
        // Clamshell, or the lid display otherwise gone: there is no notch to sit
        // in, so hide rather than park the island at the top of a monitor that
        // has none. It comes back when the display does.
        guard let screen = Self.notchedScreen else { panel.orderOut(nil); return }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - NotchIslandView.width / 2,
                              y: f.maxY - NotchIslandView.height,
                              width: NotchIslandView.width,
                              height: NotchIslandView.height),
                       display: true)
        // Paired with the hide above, so reconnecting the lid display brings the
        // island back without the user having to restart the app.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Width and height of the physical notch, or nil if this screen has none.
    static func notchSize(_ screen: NSScreen?) -> CGSize? {
        guard let screen, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }
        // +4 hides the antialiased seam where the panel meets the real notch.
        return CGSize(width: screen.frame.width - left.width - right.width + 4,
                      height: screen.safeAreaInsets.top)
    }
}

/// The island's own transport button.
///
/// Not `GlassIconButton`: there is no glass in the notch — the panel sits on
/// the black of the bezel — but the motion should be the same as the main
/// window's, so the kick behaviour is shared and only the chrome differs.
private struct NotchControl: View {
    let name: String
    var active = false
    let size: CGFloat
    var kick: IconKick = .bounce
    let action: () -> Void

    @State private var taps = 0
    @State private var nudge: CGFloat = 0
    @State private var spin: Double = 0

    var body: some View {
        Button {
            taps += 1
            switch kick {
            case .none, .bounce:
                break
            case .spin:
                withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { spin += 180 }
            case .nudge(let dx):
                withAnimation(.spring(response: 0.15, dampingFraction: 0.5)) { nudge = dx }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(130))
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.6)) { nudge = 0 }
                }
            }
            action()
        } label: {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white))
                .offset(x: nudge)
                .rotationEffect(.degrees(spin))
                .frame(width: 26, height: 24)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.6), value: bounceCount)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var bounceCount: Int {
        if case .bounce = kick { return taps }
        return 0
    }
}

struct NotchIslandView: View {
    static let width: CGFloat = 420
    static let height: CGFloat = 300

    @Bindable var model: AppModel
    let notch: CGSize

    @State private var expanded = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var pop = false

    /// Which face of the island is showing. Swipe right on the notch for the
    /// utility side, left to come back.
    private enum Face { case player, utility }
    @State private var face: Face = .player

    private var snap: EngineSnapshot { model.engine.snapshot }
    /// Only alive when there is a track. With nothing loaded the notch behaves
    /// exactly like stock macOS.
    private var live: Bool { snap.track != nil }

    var body: some View {
        // Both faces are laid out side by side and slid, rather than swapped
        // with a transition: a transition cannot know which way the swipe went,
        // so going back would animate the same direction as going forward.
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if expanded && live { island } else { chip }
                Spacer(minLength: 0)
            }
            .frame(width: Self.width, alignment: .top)
            .offset(x: face == .player ? 0 : -Self.width)

            VStack(spacing: 0) {
                NotchUtilityView(notch: notch)
                Spacer(minLength: 0)
            }
            .frame(width: Self.width, alignment: .top)
            .offset(x: face == .player ? Self.width : 0)
        }
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .clipped()
        // In the background and zero-sized: an overlay here sat on top of the
        // chip and ate its hover tracking, which stopped the island expanding.
        .background {
            TrackpadSwipe(notch: notch) { dx in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    face = dx > 0 ? .utility : .player
                }
                if dx > 0 { expanded = false }
            }
            .frame(width: 0, height: 0)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: expanded)
        .animation(.easeInOut(duration: 0.2), value: live)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: face)
        .preferredColorScheme(.dark)
        .onChange(of: snap.track?.videoId) { _, _ in
            pop = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(230))
                pop = false
            }
        }
    }

    // MARK: Collapsed — art chip left of the notch, waves right

    private var chip: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if live {
                    Artwork(url: snap.track?.artworkURL, corner: 3)
                        .frame(width: notch.height - 9, height: notch.height - 9)
                        // The collapsed chip is a few millimetres of artwork, so
                        // a track change is otherwise silent to look at. A short
                        // pop is the whole notification.
                        .scaleEffect(pop ? 1.16 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: pop)
                        .padding(.trailing, 5)
                } else {
                    Color.clear.frame(width: 1)
                }
            }
            // The notch itself: nothing is drawn here, it is the hardware.
            Color.black.opacity(0.001).frame(width: notch.width, height: notch.height)
            Group {
                if live {
                    EqualizerView(palette: model.palette,
                                  isPlaying: snap.playback.isPlaying,
                                  seed: 3, maxBlocks: 3, block: 2, gap: 2, fps: 10)
                        .frame(width: 26, height: notch.height - 8)
                        .padding(.leading, 5)
                } else {
                    Color.clear.frame(width: 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: notch.height)
        .background {
            if live {
                // Extends the black of the notch out under the chip so the two
                // read as one shape rather than as a widget stuck alongside.
                Capsule().fill(.black)
                    .frame(width: notch.width + 90, height: notch.height)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoverTask?.cancel()
            guard hovering, live else { return }
            hoverTask = Task {
                // The dwell that stops the island opening every time the pointer
                // crosses the menu bar on its way somewhere else.
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { return }
                expanded = true
            }
        }
    }

    // MARK: Expanded — design F

    private var island: some View {
        VStack(spacing: 12) {
            // The hardware notch physically covers the top of the panel, so
            // the content starts well below it. Clearing only the notch height
            // left the artwork butted right against the bezel; the extra 14
            // gives it room to read as its own shape.
            Color.clear.frame(height: notch.height + 14)

            HStack(spacing: 14) {
                EqualizerView(palette: model.palette, isPlaying: snap.playback.isPlaying,
                              seed: 0, maxBlocks: 5, block: 4, gap: 3, fps: 12)
                    .frame(width: 96, height: 92)

                Artwork(url: snap.track?.artworkURL, corner: 12)
                    .frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 3)

                EqualizerView(palette: model.palette, isPlaying: snap.playback.isPlaying,
                              seed: 7, maxBlocks: 5, block: 4, gap: 3, fps: 12)
                    .frame(width: 96, height: 92)
            }

            HStack(spacing: 22) {
                control("shuffle", active: snap.shuffled ?? false, size: 12, kick: .spin) {
                    model.shuffleQueue()
                }
                control("backward.fill", size: 15, kick: .nudge(-4)) { model.engine.previous() }
                control(snap.playback.isPlaying ? "pause.fill" : "play.fill", size: 18) {
                    model.engine.togglePlayPause()
                }
                control("forward.fill", size: 15, kick: .nudge(4)) { model.engine.next() }
                control(repeatIcon, active: (snap.repeatMode ?? "NONE") != "NONE", size: 12) {
                    model.engine.cycleRepeat()
                }
            }

            progress
            upNext
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .frame(width: 384)
        .background {
            // Square at the top so it meets the bezel cleanly, rounded below.
            UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30,
                                   style: .continuous)
                .fill(.black)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30,
                                          style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .onHover { hovering in
            hoverTask?.cancel()
            guard !hovering else { return }
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled else { return }
                expanded = false
            }
        }
    }

    private var repeatIcon: String {
        (snap.repeatMode ?? "NONE") == "ONE" ? "repeat.1" : "repeat"
    }

    /// A hairline of progress. The island is too small for a scrubber, but with
    /// nothing at all you cannot tell how far into a track you are.
    private var progress: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2.5)
        .padding(.horizontal, 6)
    }

    private var fraction: CGFloat {
        guard snap.duration > 0 else { return 0 }
        return min(max(snap.currentTime / snap.duration, 0), 1)
    }

    @ViewBuilder
    private var upNext: some View {
        let i = snap.queueIndex + 1
        if i > 0, i < snap.queue.count {
            let next = snap.queue[i]
            HStack(spacing: 7) {
                Artwork(url: next.artworkURL, corner: 4)
                    .frame(width: 18, height: 18)
                Text(next.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Text("up next")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    private func control(_ name: String, active: Bool = false, size: CGFloat,
                         kick: IconKick = .bounce,
                         _ action: @escaping () -> Void) -> some View {
        NotchControl(name: name, active: active, size: size, kick: kick, action: action)
    }
}
