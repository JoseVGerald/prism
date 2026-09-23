import SwiftUI

/// The settings popover behind the gear on Now Playing, and the same panel the
/// Settings menu opens.
///
/// Two sections in one surface rather than a gear, a crossfade popover and an
/// ambient popover competing for the same job.
struct SettingsPanel: View {
    @Bindable var model: AppModel

    private var quality: QualitySettings { model.quality }
    private var ambient: AmbientSettings { model.ambient }

    private enum Tab: String, CaseIterable, Identifiable {
        case ambient = "Ambient"
        case quality = "Quality"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .ambient
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .ambient: ambientSection
            case .quality: qualitySection
            }
        }
        .padding(20)
        .frame(width: 340)
        .task { quality.refresh() }
    }

    // MARK: Ambient (frame 1e)

    private var ambientSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Rim glow", isOn: Binding(get: { ambient.rimGlow },
                                             set: { ambient.rimGlow = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.callout)

            if ambient.rimGlow {
                labelled("Thickness", String(format: "%.0f pt", ambient.thickness)) {
                    Slider(value: Binding(get: { ambient.thickness },
                                          set: { ambient.thickness = $0.rounded() }),
                           in: 1...6, step: 1)
                }
                labelled("Glow", "\(Int(ambient.glow * 100))%") {
                    Slider(value: Binding(get: { ambient.glow },
                                          set: { ambient.glow = $0 }), in: 0...1)
                }
                labelled("Pulse", "\(Int(ambient.pulse * 100))%") {
                    Slider(value: Binding(get: { ambient.pulse },
                                          set: { ambient.pulse = $0 }), in: 0...1)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Flowing line", isOn: Binding(get: { ambient.flow },
                                                         set: { ambient.flow = $0
                                                                model.prefetchTempoIfNeeded() }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.callout)
                    Text("A light that runs round the rim, two bars a lap at the "
                         + "song's tempo, surging on each beat. The tempo is heard "
                         + "from the audio with Live audio on (and always in locked "
                         + "mode); otherwise it is AutoMix's lookup, when there is one.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Motion").font(.callout)
                    Picker("", selection: Binding(get: { ambient.motion },
                                                  set: { ambient.motion = $0
                                                         model.prefetchTempoIfNeeded() })) {
                        Text("Breathing").tag(AmbientSettings.Motion.breathing)
                        Text("Beat").tag(AmbientSettings.Motion.beat)
                        Text("Live audio").tag(AmbientSettings.Motion.liveAudio)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(motionNote)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    #if canImport(AppKit)
                    if ambient.motion == .liveAudio, model.liveAudio.failure != nil {
                        Button("Open Privacy & Security") {
                            openURL(URL(string: "x-apple.systempreferences:com.apple.preference"
                                        + ".security?Privacy_ScreenCapture")!)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    #endif
                }
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Lyric style").font(.callout)
                    Spacer()
                    Picker("", selection: Binding(get: { ambient.lyricStyle },
                                                  set: { ambient.lyricStyle = $0 })) {
                        ForEach(AmbientSettings.LyricStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                labelled("Lyrics timing", lyricsDelayLabel) {
                    Slider(value: Binding(get: { ambient.lyricsDelay },
                                          set: { ambient.lyricsDelay = ($0 * 20).rounded() / 20 }),
                           in: -0.5...1.0)
                }
                .padding(.top, 6)
                Text(ambient.lyricStyle == .random
                     ? "A different style for each song in locked mode — click the cover there to show them."
                     : "How lyrics move in locked mode — click the cover there to show them.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Show equalizers", isOn: Binding(get: { ambient.showEqualizers },
                                                        set: { ambient.showEqualizers = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.callout)
                Text("The blocks either side of the cover. Off in the lit modes by "
                     + "default; compact mode keeps both.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 5) {
                labelled("Ambient after idle", idleLabel) {
                    Slider(value: Binding(get: { ambient.idleSeconds },
                                          set: { ambient.idleSeconds = ($0 / 30).rounded() * 30 }),
                           in: 30...600, step: 30)
                }
                Text("Only on this Mac's main display. With nothing playing the "
                     + "lights fall back to a slow colourless drift.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            #if canImport(AppKit)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 5) {
                Button("Show ambient now") { model.toggleAmbient() }
                    .buttonStyle(.plainHit)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassEffect(.regular.interactive(), in: .capsule)
                Text("⌘⇧L. Covers this display until you press a key. It is a "
                     + "cover, not a lock — the Mac stays unlocked.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
    }

    private var motionNote: String {
        switch ambient.motion {
        case .breathing:
            return "A slow breath, and the colour turning around the loop."
        case .beat:
            return model.beatPeriod == nil
                ? "Pulses on the beat. No tempo is known for this track, so it "
                  + "is breathing instead — most catalogues publish no BPM at all."
                : String(format: "Pulsing at %.0f BPM, from the tempo AutoMix looks up.",
                         60 / (model.beatPeriod ?? 1))
        case .liveAudio:
            #if canImport(AppKit)
            if let failure = model.liveAudio.failure { return failure }
            #endif
            return "Reacts to the music itself — bass drives the glow, and each hit "
                 + "sends a comet round the rim. It hears the audio through macOS's "
                 + "screen capture, so the recording indicator shows while the light "
                 + "is on screen. Locked mode always reacts this way."
        }
    }

    private var lyricsDelayLabel: String {
        let d = ambient.lyricsDelay
        if abs(d) < 0.025 { return "On time" }
        return String(format: "%.2fs %@", abs(d), d > 0 ? "later" : "earlier")
    }

    private var idleLabel: String {
        let m = ambient.idleSeconds / 60
        return m < 1 ? "\(Int(ambient.idleSeconds))s"
                     : (m == m.rounded() ? "\(Int(m)) min" : String(format: "%.1f min", m))
    }

    @ViewBuilder
    private func labelled<C: View>(_ title: String, _ value: String,
                                   @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }

    // MARK: Quality

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            audio
            Divider().opacity(0.5)
            video
            Divider().opacity(0.5)
            nowStreaming
        }
    }

    // MARK: Audio

    private var audio: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("Audio quality").font(.callout.weight(.semibold))
                if quality.audioBusy || quality.audioLoading {
                    ProgressView().controlSize(.small)
                }
            }

            Picker("", selection: Binding(
                get: { quality.audioLevel ?? "Normal" },
                set: { quality.setAudioLevel($0) })) {
                    ForEach(QualitySettings.audioLevels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Only while a change is in flight. Gating on a successful read
                // as well meant one failed read left the control dead for the
                // rest of the session with no way to retry it.
                .disabled(quality.audioBusy)

            if let error = quality.audioError {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else {
                // Said plainly because the panel would otherwise look broken.
                // Measured: right after the change four tracks in a row still
                // came down at the old bitrate, and the same track was on the
                // new one a few minutes later.
                Text("This is your YouTube Music account setting, so it applies "
                     + "everywhere you listen. It reaches the stream on a later "
                     + "track — usually within a few minutes, not instantly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Video

    private var video: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Video quality").font(.callout.weight(.semibold))

            Picker("", selection: Binding(
                get: { quality.videoLevel },
                set: { quality.videoLevel = $0 })) {
                    ForEach(QualitySettings.VideoLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

            Text(quality.videoLevel.note)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: What is actually playing

    @ViewBuilder
    private var nowStreaming: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Streaming now").font(.callout.weight(.semibold))
                Spacer()
                Button {
                    quality.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plainHit)
                .help("Re-read what the player is pulling down")
            }

            if let s = quality.stream, let kbps = s.audioKbps {
                row("Audio", value: [s.audioCodec?.uppercased(), "\(kbps) kbps"]
                        .compactMap { $0 }.joined(separator: " · "),
                    detail: s.audioItag.map { "itag \($0)" })
                if let best = s.bestAudioKbps, best > kbps + 8 {
                    Text("The manifest also offers \(best) kbps. That tier is the "
                         + "High audio setting above.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let res = s.shortResolution {
                    row("Video", value: res, detail: s.videoItag.map { "itag \($0)" })
                }
            } else {
                Text("Play something and this fills in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, value: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value).font(.caption.weight(.medium))
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}
