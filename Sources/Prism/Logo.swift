import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Beamed eighth-note pair, drawn in a fixed design space and fitted to the
/// view's bounds.
struct NoteShape: Shape {
    // Bounding box of the drawing below, used to fit it into `rect`.
    private static let design = CGRect(x: 31, y: 44, width: 91, height: 99)

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 56, y: 60, width: 9, height: 68),
                         cornerSize: CGSize(width: 4.5, height: 4.5))
        p.addRoundedRect(in: CGRect(x: 111, y: 46, width: 9, height: 68),
                         cornerSize: CGSize(width: 4.5, height: 4.5))

        var beam = Path()
        beam.move(to: CGPoint(x: 56, y: 60))
        beam.addLine(to: CGPoint(x: 120, y: 46))
        beam.addLine(to: CGPoint(x: 120, y: 63))
        beam.addLine(to: CGPoint(x: 56, y: 77))
        beam.closeSubpath()
        p.addPath(beam)

        for c in [CGPoint(x: 47, y: 129), CGPoint(x: 102, y: 115)] {
            let head = Path(ellipseIn: CGRect(x: c.x - 16, y: c.y - 11.5, width: 32, height: 23))
            let tilt = CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: -20 * .pi / 180)
                .translatedBy(x: -c.x, y: -c.y)
            p.addPath(head, transform: tilt)
        }

        let b = Self.design
        let s = min(rect.width / b.width, rect.height / b.height)
        return p.applying(
            CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: s, y: s)
                .translatedBy(x: -b.midX, y: -b.midY))
    }
}

/// The mark: a white note with red and blue copies offset evenly either side.
struct LogoMark: View {
    var size: CGFloat
    /// Split distance as a fraction of the mark's size.
    var split: CGFloat = 0.055

    var body: some View {
        let d = size * split
        ZStack {
            NoteShape().fill(Color(red: 1.00, green: 0.23, blue: 0.36)).offset(x: -d)
            NoteShape().fill(Color(red: 0.04, green: 0.52, blue: 1.00)).offset(x: d)
            NoteShape().fill(.white)
        }
        .frame(width: size, height: size)
        .compositingGroup()
    }
}

/// Rounded-square app icon. The dark ground carries recognition at Dock size,
/// where the chromatic fringing itself is too fine to survive.
struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.16, green: 0.13, blue: 0.30),
                             Color(red: 0.05, green: 0.08, blue: 0.16)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            LogoMark(size: size * 0.62, split: 0.075)
        }
        .frame(width: size, height: size)
    }
}

enum DockIcon {
    /// Renders the icon and installs it at runtime, which avoids shipping an
    /// .icns and keeps the mark in one place.
    ///
    /// macOS-only by nature: an iOS app icon is a static asset baked into the
    /// bundle and cannot be replaced while running, so there is nothing here
    /// for iOS to do. The mark itself (`AppIconView`) is shared.
    @MainActor
    static func install() {
        #if canImport(AppKit)
        let renderer = ImageRenderer(content: AppIconView(size: 512))
        renderer.scale = 2
        if let image = renderer.nsImage {
            NSApp.applicationIconImage = image
        }
        #endif
    }
}
