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
    private var screenObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.reposition() }
            }
    }

    /// True on Macs that actually have a notch. Elsewhere the island would be a
    /// floating bar stuck under the menu bar, which is not what was asked for.
    static var available: Bool { notchSize(NSScreen.main) != nil }

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let screen = NSScreen.main, let notch = Self.notchSize(screen) else { return }
        if panel != nil { reposition(); panel?.orderFrontRegardless(); return }

        let size = NSSize(width: NotchIslandView.width, height: NotchIslandView.height)
        // Above the menu bar, or the island would slide underneath it.
        let p = FloatingPanel(size: size, level: .init(Int(CGWindowLevelForKey(.mainMenuWindow)) + 3),
                              movable: false)
        p.contentView = NSHostingView(
            rootView: NotchIslandView(model: model, notch: notch))
        panel = p
        reposition()
        p.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - NotchIslandView.width / 2,
                              y: f.maxY - NotchIslandView.height,
                              width: NotchIslandView.width,
                              height: NotchIslandView.height),
                       display: true)
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

struct NotchIslandView: View {
    static let width: CGFloat = 420
    static let height: CGFloat = 300

    @Bindable var model: AppModel
    let notch: CGSize

    @State private var expanded = false
    @State private var hoverTask: Task<Void, Never>?

    private var snap: EngineSnapshot { model.engine.snapshot }
    /// Only alive when there is a track. With nothing loaded the notch behaves
    /// exactly like stock macOS.
    private var live: Bool { snap.track != nil }

    var body: some View {
        VStack(spacing: 0) {
            if expanded && live { island } else { chip }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: expanded)
        .animation(.easeInOut(duration: 0.2), value: live)
        .preferredColorScheme(.dark)
    }

    // MARK: Collapsed — art chip left of the notch, waves right

    private var chip: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if live {
                    Artwork(url: snap.track?.artworkURL, corner: 3)
                        .frame(width: notch.height - 9, height: notch.height - 9)
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
                                  seed: 3, maxBlocks: 3, block: 2, gap: 2)
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
                              seed: 0, maxBlocks: 5, block: 4, gap: 3)
                    .frame(width: 96, height: 92)

                Artwork(url: snap.track?.artworkURL, corner: 12)
                    .frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 3)

                EqualizerView(palette: model.palette, isPlaying: snap.playback.isPlaying,
                              seed: 7, maxBlocks: 5, block: 4, gap: 3)
                    .frame(width: 96, height: 92)
            }

            HStack(spacing: 22) {
                control("shuffle", active: snap.shuffled ?? false, size: 12) {
                    model.shuffleQueue()
                }
                control("backward.fill", size: 15) { model.engine.previous() }
                control(snap.playback.isPlaying ? "pause.fill" : "play.fill", size: 18) {
                    model.engine.togglePlayPause()
                }
                control("forward.fill", size: 15) { model.engine.next() }
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
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
