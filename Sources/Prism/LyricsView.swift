import SwiftUI

struct LyricsToggle: View {
    @Bindable var model: AppModel

    var body: some View {
        Button { model.toggleLyrics() } label: {
            Label(model.lyricsMode ? "Cover art" : "Lyrics",
                  systemImage: model.lyricsMode ? "photo" : "quote.bubble.fill")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 13).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .hoverBloom()
        .help(model.lyricsMode ? "Back to the artwork" : "Show lyrics")
    }
}

/// Full-panel lyrics. Timed lines light up and centre themselves; untimed ones
/// are just a readable sheet, because that is all YouTube will give for tracks
/// LRCLIB has never seen.
struct LyricsView: View {
    @Bindable var model: AppModel

    private var snap: EngineSnapshot { model.engine.snapshot }
    /// The line being sung. Set from a light 20 Hz clock below rather than
    /// computed from `displayTime`, which moves once a second and left the
    /// highlight up to a second behind the singer.
    @State private var active: Int?
    @State private var clockHolder = "lyrics panel \(UUID().uuidString)"

    var body: some View {
        Group {
            if model.lyricsLoading {
                placeholder { ProgressView().controlSize(.small) }
            } else if let lyrics = model.lyrics, !lyrics.isEmpty {
                sheet(lyrics)
            } else {
                placeholder {
                    VStack(spacing: 6) {
                        Image(systemName: "quote.bubble").font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text("No lyrics found").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .background {
            // Invisible; re-evaluated twenty times a second, but `active` — and
            // so the sheet — only changes when the line does.
            if let lyrics = model.lyrics, lyrics.synced {
                TimelineView(.periodic(from: .now, by: 0.05)) { tl in
                    Color.clear
                        .onChange(of: lyrics.index(at: model.engine.smoothTime(at: tl.date)),
                                  initial: true) { _, now in active = now }
                }
            }
        }
        // The page reads the video's exact position only while this shows.
        .onAppear { model.engine.needPreciseClock(clockHolder, true) }
        .onDisappear { model.engine.needPreciseClock(clockHolder, false) }
    }

    private func sheet(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: lyrics.synced ? 14 : 7) {
                    // Breathing room so the first and last lines can still
                    // reach the middle of the panel when they are current.
                    Color.clear.frame(height: 110)

                    ForEach(lyrics.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: lyrics.synced ? 21 : 16,
                                          weight: line.id == active ? .semibold : .regular))
                            .foregroundStyle(style(for: line, synced: lyrics.synced))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 620)
                            .id(line.id)
                            .onTapGesture {
                                // Tapping a timed line is the fastest way to
                                // jump to a chorus.
                                if let at = line.at { model.engine.seek(to: at) }
                            }
                    }

                    Color.clear.frame(height: 110)
                }
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.25), value: active)
            }
            .onChange(of: active) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !lyrics.source.isEmpty {
                    Text(lyrics.synced ? lyrics.source : "\(lyrics.source) · not timed")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(8)
                }
            }
        }
    }

    private func style(for line: LyricLine, synced: Bool) -> AnyShapeStyle {
        guard synced, let active else { return AnyShapeStyle(.primary.opacity(0.85)) }
        if line.id == active { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(.primary.opacity(line.id < active ? 0.3 : 0.55))
    }

    @ViewBuilder
    private func placeholder<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }
}
