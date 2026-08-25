import SwiftUI

/// What the full-screen ambient surface draws (frame 1d).
///
/// Split out from the panel so it is a plain view: the panel owns the window,
/// this owns the picture.
struct AmbientSurface: View {
    @Bindable var model: AppModel
    var screenCorner: CGFloat = 12

    private var snap: EngineSnapshot { model.engine.snapshot }
    private var track: Track? { snap.track }
    private var playing: Bool { snap.playback.isPlaying }

    var body: some View {
        ZStack {
            Color.black
            AmbientLight(palette: model.palette,
                         isPlaying: playing,
                         thickness: model.ambient.thickness,
                         glow: model.ambient.glow,
                         corner: screenCorner,
                         inset: 10,
                         beatPeriod: model.beatPeriod,
                         pulse: model.ambient.pulse)
            content
        }
        .ignoresSafeArea()
        .environment(\.artPalette, model.palette)
        // The clock is ours to draw here. Frame 1d says "no clock — macOS draws
        // its own", but that is only true of the real Lock Screen; nothing is
        // locked, so nothing else is going to render the time.
        .overlay(alignment: .top) { clock }
        .overlay(alignment: .bottom) { hint }
    }

    // MARK: Centre

    private var content: some View {
        VStack(spacing: 26) {
            Artwork(url: track?.artworkURL, corner: 16)
                .frame(width: 260, height: 260)
                // A round glow, not a gradient filling a square frame. The
                // first version painted the radial straight into the view's own
                // bounds, so it was still coloured where it met the corners and
                // read as a lit box behind the sleeve.
                .background {
                    Circle()
                        .fill(RadialGradient(
                            colors: [model.palette.accent.opacity(0.42),
                                     model.palette.mid.opacity(0.18), .clear],
                            center: .center, startRadius: 60, endRadius: 300))
                        .frame(width: 620, height: 620)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.6), radius: 40, y: 18)

            VStack(spacing: 8) {
                Text(track?.title ?? "Nothing playing")
                    .font(.system(size: 34, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(track?.artist ?? "")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .padding(.horizontal, 60)

            if let track, snap.duration > 0 {
                progress.frame(width: 440)
                    .id(track.videoId)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 12)
    }

    private var progress: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 3)

            HStack {
                Text(timeString(model.engine.displayTime))
                Spacer()
                Text(timeString(snap.duration))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var fraction: CGFloat {
        guard snap.duration > 0 else { return 0 }
        return min(max(model.engine.displayTime / snap.duration, 0), 1)
    }

    // MARK: Chrome

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            VStack(spacing: 2) {
                Text(tl.date, format: .dateTime.hour().minute())
                    .font(.system(size: 64, weight: .thin))
                    .monospacedDigit()
                Text(tl.date, format: .dateTime.weekday(.wide).month().day())
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 10)
        .padding(.top, 64)
    }

    private var hint: some View {
        Text("Press any key to go back · media keys stay live")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.38))
            .padding(.bottom, 44)
    }
}
