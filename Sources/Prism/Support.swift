import SwiftUI

// MARK: - Formatting

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                 : String(format: "%d:%02d", m, s)
}

// MARK: - Artwork

/// Remote artwork with a graceful placeholder and a crossfade on change.
struct Artwork: View {
    let url: String?
    var corner: CGFloat = 8

    var body: some View {
        // scaledToFill has no intrinsic limit, so it grows the ZStack and the
        // clipShape below ends up clipping to that grown size rather than the
        // caller's frame. Wide 16:9 video thumbnails then spill out of their
        // box, shunting row text sideways and bleeding into the equalizer.
        // Pinning to the geometry and clipping there is what actually contains it.
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.white.opacity(0.06))
                if let url, let parsed = URL(string: url) {
                    AsyncImage(url: parsed,
                               transaction: .init(animation: .easeOut(duration: 0.25))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .transition(.opacity)
                        } else if phase.error != nil {
                            Image(systemName: "music.note").foregroundStyle(.secondary)
                        } else {
                            Color.clear
                        }
                    }
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }
}

/// Samples the desktop *behind the window* rather than the views beneath it.
/// That is the whole trick: it reads as genuine translucency while still
/// occluding the engine webview, which lives inside the window.
#if canImport(AppKit)
struct DesktopBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
#else
/// iOS has no desktop to sample — an app owns the whole screen — so there is
/// nothing behind the window to show through.
///
/// The first attempt here was `.ultraThinMaterial`, reasoning that it is the
/// nearest equivalent. It is not: a material with nothing behind it composites
/// against black and renders as flat near-black, which is exactly what the app
/// looked like. The glass panels then had nothing to refract and the idle
/// aurora, tuned to sit at 26–34% over a *lit desktop*, was invisible.
///
/// So iOS gets a real base of its own rather than a translucency effect with
/// no source. Deliberately not a screenshot of the wallpaper pretending to be
/// live: a still image would look wrong the moment anything moved.
struct DesktopBlur: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.10, green: 0.10, blue: 0.14),
                     Color(red: 0.05, green: 0.05, blue: 0.08)],
            startPoint: .top, endPoint: .bottom)
    }
}
#endif

/// The layer that gives the glass panels something worth refracting: the
/// desktop showing through, with blurred album art washed over the top.
struct Backdrop: View {
    let url: String?

    var body: some View {
        ZStack {
            #if canImport(AppKit)
            DesktopBlur(material: .hudWindow)
            #else
            DesktopBlur()
            #endif

            if let url, let parsed = URL(string: url) {
                // scaledToFill without an explicit frame reports the image's own
                // huge intrinsic size, which inflates the root ZStack and shoves
                // the whole UI out of the window. Pin it to the geometry.
                GeometryReader { geo in
                    AsyncImage(url: parsed,
                               transaction: .init(animation: .easeInOut(duration: 0.9))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .blur(radius: 110, opaque: true)
                                .saturation(2.4)
                                .opacity(0.72)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                // Nothing playing: a faint aurora, kept translucent so the
                // desktop still reads through it.
                // Opacities differ by platform on purpose: on macOS this tints
                // a desktop that is already providing light, on iOS it *is*
                // the light.
                #if canImport(AppKit)
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.14, blue: 0.45).opacity(0.34),
                             Color(red: 0.06, green: 0.22, blue: 0.38).opacity(0.26),
                             Color(red: 0.28, green: 0.10, blue: 0.34).opacity(0.34)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                #else
                LinearGradient(
                    colors: [Color(red: 0.24, green: 0.16, blue: 0.52),
                             Color(red: 0.07, green: 0.24, blue: 0.42),
                             Color(red: 0.32, green: 0.11, blue: 0.38)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                #endif
            }

            // Enough scrim to hold white text and to sit the equalizer against,
            // without killing the glass.
            #if canImport(AppKit)
            LinearGradient(
                colors: [.black.opacity(0.36), .black.opacity(0.18), .black.opacity(0.42)],
                startPoint: .top, endPoint: .bottom)
            #else
            LinearGradient(
                colors: [.black.opacity(0.22), .black.opacity(0.06), .black.opacity(0.30)],
                startPoint: .top, endPoint: .bottom)
            #endif
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.9), value: url)
    }
}

// MARK: - Glass building blocks

/// A circular glass control. `prominent` is used for the play button.
struct GlassIconButton: View {
    let system: String
    var size: CGFloat = 15
    var diameter: CGFloat = 34
    var prominent = false
    var active = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.black)
                                           : AnyShapeStyle(active ? Color.accentColor : .primary))
                .frame(width: diameter, height: diameter)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .background {
            if prominent {
                Circle().fill(.white)
            } else {
                Circle().fill(.clear)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .overlay {
            if active && !prominent {
                Circle().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
        }
        .scaleEffect(hovering ? 1.07 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Draggable progress bar that reports scrub start/commit separately so the
/// engine's ticks do not fight the user's thumb.
struct Scrubber: View {
    let value: Double
    let total: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fraction = total > 0 ? min(max(value / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white).frame(width: w * fraction)
                Circle()
                    .fill(.white)
                    .frame(width: dragging ? 12 : 9, height: dragging ? 12 : 9)
                    .shadow(radius: 3)
                    .offset(x: w * fraction - (dragging ? 6 : 4.5))
                    .opacity(dragging ? 1 : 0.9)
            }
            .frame(height: dragging ? 6 : 4)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        onScrub(min(max(g.location.x / w, 0), 1) * total)
                    }
                    .onEnded { g in
                        dragging = false
                        onCommit(min(max(g.location.x / w, 0), 1) * total)
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 14)
    }
}

// Moved here from RootView so the iOS build can use it: the modifier is
// platform-neutral and only happened to live in a macOS-only file.
/// Glass that can be switched off, so a pane can go fully clear in video mode.
struct PaneGlass: ViewModifier {
    let enabled: Bool
    var corner: CGFloat = 20

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular, in: .rect(cornerRadius: corner))
        } else {
            content
        }
    }
}

/// Words that name the machine.
///
/// A handful of strings say "this Mac". They are user-facing and shared, so
/// they ask here rather than being forked per platform.
enum PlatformInteraction {
    /// How visible a row's actions are when the pointer is not on them.
    ///
    /// On macOS these dim to near-invisible until hovered, which keeps a long
    /// list calm. There is no hover on iOS, so `onHover` never fires and the
    /// same expression would leave every control stuck at a third opacity,
    /// permanently reading as disabled while still being tappable. On touch
    /// they are simply always visible.
    static var restingActionOpacity: Double {
        #if canImport(AppKit)
        return 0.32
        #else
        return 1
        #endif
    }
}

enum PlatformWording {
    static var thisDevice: String {
        #if canImport(AppKit)
        return "this Mac"
        #else
        return "this iPhone"
        #endif
    }
}

/// Keeps glass and white text legible over a music video. Moved here from
/// RootView so the iOS build shares it — the layer is platform-neutral.
struct VideoScrim: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [.black.opacity(0.02), .black.opacity(0.22), .black.opacity(0.55)],
                center: .center, startRadius: 200, endRadius: 900)
            LinearGradient(
                colors: [.black.opacity(0.30), .clear, .black.opacity(0.38)],
                startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
