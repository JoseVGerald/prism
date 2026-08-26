#if canImport(AppKit)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Catches a two-finger trackpad swipe over the notch.
///
/// Not a `DragGesture`: a two-finger swipe on a trackpad is not a drag, it is a
/// scroll with no click, so SwiftUI's drag gestures never see it. It arrives as
/// `scrollWheel`.
///
/// Two earlier attempts are worth recording, because both failed for reasons
/// that are easy to walk back into.
///
/// An `NSView` in a SwiftUI `.overlay` receives the scroll, but it also sits in
/// front of the chip and takes part in hit-testing — the island stopped
/// expanding, because `.onHover` underneath never saw the pointer again.
///
/// A local `NSEvent` monitor occupies no space, but never fired: the island's
/// panel is non-activating and cannot become key, so scrolls over it are not
/// dispatched to this application the way mouse-moved events are.
///
/// So the handler is the hosting view's *parent*. Ancestors get `scrollWheel`
/// through the responder chain when no descendant consumes it, which means this
/// sees every swipe over the panel while occupying no space in the layout and
/// covering nothing.
final class NotchSwipeHost: NSView {
    /// Positive is a swipe to the right.
    var onSwipe: ((CGFloat) -> Void)?
    var notch: CGSize = .zero

    private var travel: CGFloat = 0
    private var fired = false
    private let threshold: CGFloat = 20

    /// `~/.prism-eval/swipe.log`, and only under PRISM_EVAL. A gesture that does
    /// nothing is indistinguishable from one that never arrived; this says which.
    private static let logURL: URL? = {
        guard ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1" else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".prism-eval/swipe.log")
    }()

    private func log(_ line: String) {
        guard let url = Self.logURL else { return }
        let text = line + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let p = event.locationInWindow
        log(String(format: "scroll precise=%@ phase=%lu momentum=%lu dx=%.1f dy=%.1f at (%.0f,%.0f)",
                   event.hasPreciseScrollingDeltas ? "Y" : "N",
                   event.phase.rawValue, event.momentumPhase.rawValue,
                   event.scrollingDeltaX, event.scrollingDeltaY, p.x, p.y))

        // A mouse wheel has no horizontal axis worth reading here and should
        // keep scrolling whatever is underneath.
        guard event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }

        // No position gate. There was one — "must be within the notch strip" —
        // and it rejected every real swipe: 1248 scroll events logged, none
        // accepted, because the pointer sits around y=190 in a 300pt panel
        // rather than up in the top 32pt where the notch is drawn. Scrolls only
        // reach this view when the pointer is over the panel at all, and the
        // panel *is* the island, so being over it is the whole test.

        switch event.phase {
        case .began:
            travel = 0
            fired = false
        case .ended, .cancelled:
            travel = 0
            fired = false
        default:
            break
        }

        travel += event.scrollingDeltaX
        // Horizontal intent only: a mostly-vertical scroll that drifts sideways
        // should not flip the page.
        guard !fired, abs(travel) > threshold,
              abs(travel) > abs(event.scrollingDeltaY) * 1.5 else { return }
        fired = true
        log("  -> swipe \(travel > 0 ? "RIGHT" : "LEFT") (travel \(Int(travel)))")
        onSwipe?(travel)
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
