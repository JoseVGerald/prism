import SwiftUI

struct NowPlayingBar: View {
    @Bindable var model: AppModel

    private var engine: Engine { model.engine }
    private var snap: EngineSnapshot { engine.snapshot }
    private var track: Track? { snap.track }

    @State private var volume: Double = 100
    @State private var volumeInitialised = false

    var body: some View {
        // The transport is centred against the whole bar, not against the space
        // left over between the side blocks. Those are 230pt and 130pt wide, so
        // an HStack would put "centre" 50pt to the right of the real one — the
        // play button visibly misaligned with the artwork above it.
        ZStack {
            HStack(spacing: 16) {
                identity
                Spacer(minLength: 12)
                volumeControls
            }
            transport.frame(width: 520)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .onChange(of: snap.volume) { _, v in
            // Adopt the engine's volume once, then let the slider own it.
            if !volumeInitialised { volume = v; volumeInitialised = true }
        }
    }

    // MARK: Pieces

    private var identity: some View {
        HStack(spacing: 11) {
                Artwork(url: track?.artworkURL, corner: 8)
                    .frame(width: 50, height: 50)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "Nothing playing")
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Text(track?.artist ?? "—")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        .frame(width: 230, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.route = .nowPlaying }
    }

    private var transport: some View {
        VStack(spacing: 5) {
                HStack(spacing: 10) {
                    GlassIconButton(system: "shuffle", size: 13, diameter: 30,
                                    active: snap.shuffled ?? false,
                                    kick: .spin, palette: model.palette) { model.shuffleQueue() }
                        .help("Shuffle what is coming up")
                    GlassIconButton(system: "backward.fill", size: 13, diameter: 32,
                                    kick: .nudge(-5), palette: model.palette) {
                        engine.previous()
                    }
                    GlassIconButton(system: snap.playback.isPlaying ? "pause.fill" : "play.fill",
                                    size: 17, diameter: 44, prominent: true, palette: model.palette) {
                        engine.togglePlayPause()
                    }
                    GlassIconButton(system: "forward.fill", size: 13, diameter: 32,
                                    kick: .nudge(5), palette: model.palette) {
                        engine.next()
                    }
                    GlassIconButton(system: repeatIcon, size: 13, diameter: 30,
                                    active: snap.repeatMode != "NONE") { engine.cycleRepeat() }
                        .help("Repeat: \(snap.repeatMode?.capitalized ?? "none")")
                }

                HStack(spacing: 9) {
                    Text(timeString(engine.displayTime))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Scrubber(value: engine.displayTime, total: snap.duration) { t in
                        engine.scrubOverride = t
                    } onCommit: { t in
                        engine.seek(to: t)
                        engine.scrubOverride = nil
                    }
                    Text(timeString(snap.duration))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
            }
        }
    }

    private var volumeControls: some View {
        HStack(spacing: 8) {
            CrossfadeControl(model: model)
            Button {
                if snap.muted || volume == 0 { engine.setVolume(70); volume = 70 }
                else { engine.setVolume(0); volume = 0 }
            } label: {
                Image(systemName: volumeIcon).font(.system(size: 12))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            Slider(value: $volume, in: 0...100) { editing in
                if !editing { engine.setVolume(volume) }
            }
            .controlSize(.mini)
            .frame(width: 90)
            .onChange(of: volume) { _, v in engine.setVolume(v) }
        }
        // Widened from 130: the crossfade button pushed the slider past the
        // old frame. The identity block opposite is 230, and the transport is
        // centred against the whole bar rather than the gap between them, so
        // this width does not move the play button.
        .frame(width: 168, alignment: .trailing)
    }

    private var repeatIcon: String {
        switch snap.repeatMode {
        case "ONE": return "repeat.1"
        default:    return "repeat"
        }
    }

    private var volumeIcon: String {
        if snap.muted || volume == 0 { return "speaker.slash.fill" }
        if volume < 33 { return "speaker.wave.1.fill" }
        if volume < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
