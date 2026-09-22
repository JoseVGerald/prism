#if canImport(AppKit)
import SwiftUI
import AppKit

/// What the full-screen ambient surface draws (frame 1d, extended).
///
/// Two faces: the **cover** — art, title, progress and clock — and **lyrics**,
/// reached by clicking the cover. Around both runs the rim, which in locked
/// mode always listens to the music. As a song ends, the screen splits between
/// it and the next one and the rim's colours change hands.
///
/// Any key still leaves. The mouse only gains powers: click the cover for
/// lyrics, hover it for controls, drag the bar to seek, scroll for volume.
/// A click on empty space still leaves — handled here, as the *root* tap
/// gesture, so SwiftUI gives every control's own gesture priority over it and
/// a click on a button can never also close the surface.
struct AmbientSurface: View {
    @Bindable var model: AppModel
    var screenCorner: CGFloat = 12

    @State private var showingLyrics = false
    @State private var hoveringArt = false
    @State private var chromeVisible = true
    @State private var idleTask: Task<Void, Never>?
    @State private var latch = AmbientTransition.Latch()
    /// This song's style when the setting is Random, picked as the song starts.
    @State private var randomStyle: AmbientSettings.LyricStyle = .prism

    private var snap: EngineSnapshot { model.engine.snapshot }
    private var track: Track? { snap.track }
    private var playing: Bool { snap.playback.isPlaying }

    /// Whether a hand-over could be drawn at all right now. The root timeline
    /// only needs to tick near the end of a song; the rest of the time it is
    /// paused and the surface redraws only when something it reads changes,
    /// rather than rebuilding every view twenty times a second for nothing.
    private var nearHandover: Bool {
        if model.transitions.fadeClock != nil || latch.holding { return true }
        let d = snap.duration
        return model.nextEntry != nil && d > 0
            && d - snap.currentTime < AmbientTransition.fallbackWindow + 1
    }

    var body: some View {
        // At the display's pace while a hand-over runs — at 20fps the cards
        // visibly stepped — and paused the rest of the time.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !nearHandover)) { tl in
            let raw = AmbientTransition.progress(model: model, at: tl.date, latch: latch)
            let e = AmbientTransition.smoothstep(0, 1, raw ?? 0)
            ZStack {
                Color.black
                if showingLyrics {
                    backdrop(progress: e)
                } else if e > 0 {
                    TransitionFields(from: model.palette, to: model.nextPalette, progress: e)
                }

                AmbientLight(palette: ArtPalette.blend(model.palette, model.nextPalette, e),
                             isPlaying: playing,
                             thickness: model.ambient.thickness,
                             glow: model.ambient.glow,
                             corner: screenCorner,
                             inset: 10,
                             pulse: model.ambient.pulse,
                             audio: model.audioSource,
                             flow: model.ambient.flow,
                             tempo: model.trackTempo)

                if showingLyrics { lyricsFace } else { coverFace(progress: e) }
            }
        }
        .ignoresSafeArea()
        .environment(\.artPalette, model.palette)
        .overlay(alignment: .top) { clock }
        .overlay(alignment: .bottom) { hint }
        .overlay { volumeHUD }
        // Any click that no control claimed leaves, as a click always did.
        .contentShape(Rectangle())
        .onTapGesture { model.dismissAmbient() }
        .onContinuousHover { phase in
            if case .active = phase { wake() }
        }
        .onAppear {
            // Locked mode always reacts to the music; the capture is held for
            // exactly as long as this surface is up.
            model.liveAudio.set("locked mode", true)
            wake()
        }
        .onDisappear {
            model.liveAudio.set("locked mode", false)
            model.ambientLyricsWanted = false
            idleTask?.cancel()
        }
        .animation(.easeInOut(duration: 0.45), value: showingLyrics)
        .animation(.easeOut(duration: 0.3), value: chromeVisible)
        .onChange(of: track?.videoId, initial: true) { pickRandomStyle() }
    }

    /// A different drawn style from the last song's, so Random never repeats
    /// itself back to back.
    private func pickRandomStyle() {
        let others = AmbientSettings.LyricStyle.drawn.filter { $0 != randomStyle }
        randomStyle = others.randomElement() ?? .prism
    }

    private var lyricStyle: AmbientSettings.LyricStyle {
        model.ambient.lyricStyle == .random ? randomStyle : model.ambient.lyricStyle
    }

    // MARK: Cover face

    /// One song's card. Keyed by video id, so when the incoming song becomes
    /// the current one it is the *same view* — its artwork already loaded, its
    /// layout already in place — rather than a new card that reloads the art
    /// and gains a progress bar as the song changes.
    private struct Slot: Identifiable {
        let id: String
        let incoming: Bool
        let title: String
        let artist: String
        let art: String?
        let palette: ArtPalette
    }

    private var slots: [Slot] {
        var out = [Slot(id: track?.videoId ?? "none", incoming: false,
                        title: track?.title ?? "Nothing playing", artist: track?.artist ?? "",
                        art: ArtworkURL.large(track?.artworkURL), palette: model.palette)]
        if let next = model.nextEntry, next.videoId != track?.videoId {
            out.append(Slot(id: next.videoId, incoming: true, title: next.title,
                            artist: next.artist, art: ArtworkURL.large(next.artworkURL),
                            palette: model.nextPalette))
        }
        return out
    }

    private func coverFace(progress e: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                ForEach(slots) { slot in
                    // The outgoing song shrinks, slides left and fades, while the
                    // next grows in from the right to exactly where the cover
                    // sits. At 1 the incoming card is the cover, pixel for pixel,
                    // so the moment the song changes nothing moves. It is also
                    // there unseen before the hand-over, which loads its art.
                    card(slot, interactive: !slot.incoming && e < 0.05)
                        .scaleEffect(slot.incoming ? 0.45 + 0.55 * e : 1 - 0.55 * e)
                        .offset(x: slot.incoming ? w * 0.3 * (1 - e) : -w * 0.28 * e)
                        .opacity(slot.incoming ? AmbientTransition.smoothstep(0, 0.6, e)
                                               : 1 - AmbientTransition.smoothstep(0.35, 1, e))
                        .allowsHitTesting(!slot.incoming)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func card(_ slot: Slot, interactive: Bool) -> some View {
        VStack(spacing: 26) {
            art(slot.art, palette: slot.palette, interactive: interactive)
            titles(slot.title, slot.artist)
            // The same height on both cards, so the incoming one's layout
            // already matches when the progress bar fades in on it.
            ZStack {
                if !slot.incoming, track != nil, snap.duration > 0 {
                    progress.transition(.opacity)
                }
            }
            .frame(width: 440, height: 40)
            .animation(.easeOut(duration: 0.5), value: slot.incoming)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 12)
    }

    private func titles(_ title: String, _ artist: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(artist)
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 60)
    }

    private func art(_ url: String?, palette: ArtPalette, interactive: Bool) -> some View {
        Artwork(url: url, corner: 16)
            .frame(width: 260, height: 260)
            .background {
                Circle()
                    .fill(RadialGradient(
                        colors: [palette.accent.opacity(0.42),
                                 palette.mid.opacity(0.18), .clear],
                        center: .center, startRadius: 60, endRadius: 300))
                    .frame(width: 620, height: 620)
                    .allowsHitTesting(false)
            }
            .overlay { if interactive && hoveringArt && chromeVisible { artControls } }
            .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
            .contentShape(Rectangle())
            .onHover { hoveringArt = $0 }
            .onTapGesture {
                guard interactive else { return }
                showingLyrics = true
                model.ambientLyricsWanted = true
            }
            .help("Click for lyrics")
    }

    private var artControls: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.45))
            transport(size: 1)
        }
        .transition(.opacity)
    }

    private func transport(size k: CGFloat) -> some View {
        HStack(spacing: 18 * k) {
            GlassIconButton(system: "backward.fill", size: 16 * k, diameter: 44 * k,
                            kick: .nudge(-5), palette: model.palette) { model.engine.previous() }
            GlassIconButton(system: playing ? "pause.fill" : "play.fill",
                            size: 22 * k, diameter: 60 * k, prominent: true,
                            palette: model.palette) { model.engine.togglePlayPause() }
            GlassIconButton(system: "forward.fill", size: 16 * k, diameter: 44 * k,
                            kick: .nudge(5), palette: model.palette) { model.engine.next() }
        }
    }

    private var progress: some View {
        VStack(spacing: 7) {
            Scrubber(value: model.engine.displayTime, total: snap.duration) { t in
                model.engine.scrubOverride = t
            } onCommit: { t in
                model.engine.seek(to: t)
                model.engine.scrubOverride = nil
            }
            HStack {
                Text(timeString(model.engine.displayTime))
                Spacer()
                Text(timeString(snap.duration))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: Lyrics face

    private var lyricsFace: some View {
        ZStack {
            // Keyed by song, so as one song gives way to the next its lyrics
            // fade out while the new song's fade in, rather than cutting.
            AmbientLyricsView(model: model, style: lyricStyle)
                .id(track?.videoId)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.8), value: track?.videoId)
                .padding(.horizontal, 80)
                .contentShape(Rectangle())
                // Clicking the lyrics goes back to the cover.
                .onTapGesture { showingLyrics = false; model.ambientLyricsWanted = false }

            VStack {
                HStack {
                    // The cover, small, as the way back and a reminder of the song.
                    Button { showingLyrics = false; model.ambientLyricsWanted = false } label: {
                        HStack(spacing: 12) {
                            Artwork(url: track?.artworkURL, corner: 8).frame(width: 54, height: 54)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track?.title ?? "").font(.system(size: 15, weight: .semibold))
                                Text(track?.artist ?? "").font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .hoverBloom()
                    Spacer()
                }
                .padding(.leading, 44).padding(.top, 40)
                Spacer()
                if chromeVisible {
                    VStack(spacing: 14) {
                        transport(size: 0.8)
                        if snap.duration > 0 { progress.frame(width: 440) }
                    }
                    .padding(.bottom, 70)
                    .transition(.opacity)
                }
            }
        }
        .transition(.opacity)
    }

    /// The blurred covers behind the lyrics, keyed by image: the next song's,
    /// faded up over the hand-over, is the very layer that stays once the song
    /// changes. Two positional layers used to swap contents at that moment,
    /// flashing the old cover back for a beat.
    private func backdrop(progress e: Double) -> some View {
        var layers = [(url: ArtworkURL.large(track?.artworkURL) ?? "none", opacity: 1.0)]
        if e > 0, let next = ArtworkURL.large(model.nextEntry?.artworkURL), next != layers[0].url {
            layers.append((next, e))
        }
        return ZStack {
            ForEach(layers, id: \.url) { layer in
                BlurredArtBackdrop(url: layer.url == "none" ? nil : layer.url)
                    .opacity(layer.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Chrome

    /// Controls and cursor stay while the mouse moves, and fade after 3s of
    /// stillness so the screen is just the art or the lyrics.
    private func wake() {
        if !chromeVisible { chromeVisible = true }
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            chromeVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            VStack(spacing: 2) {
                Text(tl.date, format: .dateTime.hour().minute())
                    .font(.system(size: showingLyrics ? 30 : 64, weight: .thin))
                    .monospacedDigit()
                if !showingLyrics {
                    Text(tl.date, format: .dateTime.weekday(.wide).month().day())
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 10)
        .padding(.top, showingLyrics ? 42 : 64)
        .allowsHitTesting(false)
    }

    private var hint: some View {
        Text(showingLyrics ? "Any key to go back · click the lyrics for the cover"
                           : "Any key to go back · click the cover for lyrics · media keys stay live")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(chromeVisible ? 0.38 : 0))
            .padding(.bottom, 44)
            .allowsHitTesting(false)
    }

    private var volumeHUD: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let shown = model.volumeHUDAt.map { tl.date.timeIntervalSince($0) < 1.2 } ?? false
            HStack(spacing: 12) {
                Image(systemName: model.volumeHUDLevel == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                Capsule().fill(.white.opacity(0.2))
                    .frame(width: 180, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: 180 * model.volumeHUDLevel / 100, height: 5)
                    }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Capsule().fill(.black.opacity(0.55)))
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: shown)
        }
        .allowsHitTesting(false)
    }
}
#endif
