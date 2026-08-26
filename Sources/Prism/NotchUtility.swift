#if canImport(AppKit)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Catches a two-finger trackpad swipe over the notch.
///
/// Not a `DragGesture`: a two-finger swipe on a trackpad is not a drag, it is a
/// scroll with no click, so SwiftUI's drag gestures never see it. It arrives as
/// `scrollWheel` with precise deltas, which is what this listens for.
struct TrackpadSwipe: NSViewRepresentable {
    /// Positive is a swipe to the right.
    var onSwipe: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = SwipeView()
        v.onSwipe = onSwipe
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? SwipeView)?.onSwipe = onSwipe
    }

    final class SwipeView: NSView {
        var onSwipe: ((CGFloat) -> Void)?
        private var travel: CGFloat = 0
        private var fired = false

        /// Enough travel to mean it, low enough not to need a shove.
        private let threshold: CGFloat = 26

        override func scrollWheel(with event: NSEvent) {
            // `hasPreciseScrollingDeltas` is what separates a trackpad from a
            // mouse wheel. A wheel has no horizontal axis worth reading here and
            // should keep scrolling whatever is underneath.
            guard event.hasPreciseScrollingDeltas else {
                super.scrollWheel(with: event)
                return
            }

            switch event.phase {
            case .began:
                travel = 0
                fired = false
            case .changed:
                travel += event.scrollingDeltaX
                // Horizontal intent only: a mostly-vertical scroll that drifts
                // sideways should not flip the page.
                guard !fired, abs(travel) > threshold,
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                else { return }
                fired = true
                onSwipe?(travel)
            case .ended, .cancelled:
                travel = 0
                fired = false
            default:
                break
            }
        }
    }
}

/// The utility face of the island: the time, and somewhere to drop files.
///
/// Reached by swiping right on the notch, and left again to go back.
struct NotchUtilityView: View {
    let notch: CGSize

    var body: some View {
        VStack(spacing: 0) {
            // The hardware notch covers the top of the panel, so nothing worth
            // reading starts above it.
            Color.clear.frame(height: notch.height + 10)

            HStack(spacing: 16) {
                clock
                Divider().frame(height: 74).opacity(0.18)
                AirDropWell()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 384)
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30,
                                   style: .continuous)
                .fill(.black)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30,
                                          style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            VStack(alignment: .leading, spacing: 2) {
                Text(tl.date, format: .dateTime.hour().minute())
                    .font(.system(size: 34, weight: .light))
                    .monospacedDigit()
                Text(tl.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white)
        }
        .frame(width: 130, alignment: .leading)
    }
}

/// Drop files here and macOS opens its own AirDrop picker.
///
/// `NSSharingService` is the supported route — there is no API to send to a
/// specific person, and there should not be: choosing the recipient is the
/// system's job and the picker is what asks.
private struct AirDropWell: View {
    @State private var targeted = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "wifi")
                .font(.system(size: 20, weight: .medium))
                .rotationEffect(.degrees(targeted ? 0 : -45))
                .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor)
                                          : AnyShapeStyle(.white.opacity(0.75)))
            Text(note ?? (targeted ? "Release to send" : "Drop to AirDrop"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(targeted ? 0.12 : 0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.white.opacity(targeted ? 0.5 : 0.18))
                }
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            send(urls)
        } isTargeted: { targeted = $0 }
    }

    private func send(_ urls: [URL]) -> Bool {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else {
            flash("Only files can be sent")
            return false
        }
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: files) else {
            flash("AirDrop is unavailable")
            return false
        }
        // The picker is a real window and will not come forward on its own: the
        // island's panel deliberately never becomes key, so without this the
        // drop appears to do nothing at all.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: files)
        flash(files.count == 1 ? "Sending 1 file" : "Sending \(files.count) files")
        return true
    }

    private func flash(_ text: String) {
        note = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            note = nil
        }
    }
}
#endif
