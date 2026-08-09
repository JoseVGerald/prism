import SwiftUI
import WebKit

/// Hosts the engine's webview. It stays mounted at full size for the whole
/// session — WebKit throttles or suspends media in views that are detached or
/// zero-sized, so it is layered *behind* the opaque backdrop rather than hidden.
struct EngineWebView: View {
    let engine: Engine
    var body: some View { EngineWebViewHost(webView: engine.webView) }
}

struct RootView: View {
    @Bindable var model: AppModel

    private var engine: Engine { model.engine }
    private var snap: EngineSnapshot { engine.snapshot }

    var body: some View {
        ZStack {
            // In video mode the webview stops being a hidden engine and becomes
            // the app's background: the page is restyled so the <video> fills
            // it, and the panels above are glass, so the picture reads through.
            // Behind the webview in video mode, so the areas the video layer
            // leaves uncovered show blurred artwork rather than black.
            if model.videoMode && !engine.showingEngine {
                Backdrop(url: snap.track?.artworkURL)
            }

            EngineWebView(engine: engine)
                // Measured and corrected, never read live — see
                // AppModel.measureVideoFill for why both matter.
                .modifier(VideoFill(placement: model.videoMode && !engine.showingEngine
                                               ? model.videoPlacement : nil))
                .opacity(engine.showingEngine || model.videoMode ? 1 : 0)
                .zIndex(engine.showingEngine ? 10 : 0)

            if !engine.showingEngine {
                if model.videoMode {
                    VideoScrim()
                } else {
                    Backdrop(url: snap.track?.artworkURL)
                }

                // Deliberately *not* wrapped in a GlassEffectContainer: that
                // groups glass shapes for morphing and cannot lay out an app
                // shell containing scroll views — it lets their content escape
                // the panel frames entirely.
                if model.compact {
                    CompactNowPlaying(model: model)
                        .transition(.opacity)
                        .modifier(EscapeToExit { model.toggleCompact() })
                } else {
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            Sidebar(model: model)
                            ContentPane(model: model)
                            if model.showQueue {
                                QueuePanel(model: model)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        NowPlayingBar(model: model)
                    }
                    .padding(14)
                    .padding(.top, 22)          // clearance for the traffic lights
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.showQueue)
                    .transition(.opacity)
                }

                if engine.isBooting { BootOverlay() }
            }

            if engine.showingEngine { SignInChrome(engine: engine) }

            // A real ZStack child with an explicit zIndex, not an .overlay.
            // As an overlay it never appeared on screen, which also meant
            // enqueue results were invisible and undiagnosable.
            if let status = model.status {
                VStack {
                    Spacer()
                    Text(status)
                        .font(.callout)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .glassEffect(.regular, in: .capsule)
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
                        .padding(.bottom, model.compact ? 30 : 118)
                        .onTapGesture { model.status = nil }
                }
                .zIndex(50)
                .transition(.opacity)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.22), value: model.status)
        // .task(id:) rather than .onChange: a track is usually already playing
        // when the window appears, and onChange alone never fires for it.
        .task(id: snap.track?.artworkURL) {
            model.refreshPalette(for: snap.track?.artworkURL)
        }
        // One funnel for everything that reacts to engine state: the listening
        // log, the system Now Playing tile, crossfade timing, and lyrics.
        .onChange(of: snap.currentTime) { _, _ in model.onSnapshot(snap) }
        .background {
            GeometryReader { geo in
                let si = geo.safeAreaInsets
                Color.clear.onChange(of: geo.size, initial: true) { _, size in
                    let full = CGSize(width: size.width + si.leading + si.trailing,
                                      height: size.height + si.top + si.bottom)
                    guard model.windowSize != full else { return }
                    model.windowSize = full
                    // A resized window invalidates a placement measured against
                    // the old one, so re-measure rather than leave black edges.
                    if model.videoMode { model.measureVideoFill() }
                }
            }
        }
        .onChange(of: snap.track?.videoId) { _, _ in model.onSnapshot(snap) }
        .onChange(of: snap.hasVideo) { _, has in model.syncVideoMode(hasVideo: has) }
        // The mini player and the notch island belong to this window's session,
        // so they go when it does rather than stranding panels with no way back.
        .onDisappear { model.closeFloating() }
        .animation(.easeInOut(duration: 0.35), value: model.videoMode)
    }
}

/// Slides and enlarges the webview so the video's painted region lands exactly
/// on the window.
///
/// The page refuses to be rearranged — repositioning the player moves its
/// layout box while the picture keeps painting where YouTube's compositor puts
/// it. So instead of moving the video inside the page, the page is grown by the
/// chrome around the video and pushed up and left by the same amount. Those
/// insets are fixed-pixel (guide width, nav height), so this converges rather
/// than oscillating. No scaling, so no softening.
struct VideoFill: ViewModifier {
    let placement: VideoPlacement?

    func body(content: Content) -> some View {
        if let p = placement, p.width > 40, p.height > 40 {
            GeometryReader { geo in
                // GeometryReader measures inside the safe area, so the window's
                // true bounds include the transparent title-bar strip above it.
                let si = geo.safeAreaInsets
                content
                    .frame(width: p.width, height: p.height)
                    .offset(x: p.dx - si.leading, y: p.dy - si.top)
            }
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
    }
}

/// Darkens the video enough to keep white text and glass panels legible, while
/// leaving the middle — where the artwork used to sit — comparatively clear, so
/// the now-playing area reads as the video window.


/// Escape handling, at the AppKit level.
///
/// Neither `.onExitCommand` nor a zero-sized button with `.keyboardShortcut`
/// fires here, because nothing in the compact view takes keyboard focus. The
/// monitor is installed only while compact mode is on screen.
private struct EscapeToExit: ViewModifier {
    let action: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                #if canImport(AppKit)
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 53 else { return event }   // Escape
                    action()
                    return nil
                }
                #endif
            }
            .onDisappear {
                #if canImport(AppKit)
                if let m = monitor { NSEvent.removeMonitor(m) }
                monitor = nil
                #endif
            }
    }
}

private struct BootOverlay: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Starting engine…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(34)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Thin bar shown while the raw YouTube page is exposed for Google sign-in.
private struct SignInChrome: View {
    let engine: Engine

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Text("Sign in to YouTube Music, then come back.")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Done") { engine.endSignIn() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.top, 30)
            Spacer()
        }
        .zIndex(20)
    }
}

// MARK: - Full sidebar

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The wordmark is the way back to For You, which is also where
            // Prism opens the very first time it runs.
            Button {
                model.route = .forYou
                model.loadSuggestions(force: true)
            } label: {
                HStack(spacing: 9) {
                    LogoMark(size: 25)
                    Text("Prism")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("For You")
            .padding(.horizontal, 11).padding(.top, 7).padding(.bottom, 11)

            item("For You", "sparkles", isActive(.forYou)) { model.route = .forYou }
            item("Now Playing", "play.circle", isActive(.nowPlaying)) { model.route = .nowPlaying }
            item("Search", "magnifyingglass", isActive(.search)) { model.route = .search }
            item("Library", "square.stack", isActive(.library)) {
                model.route = .library
                model.loadLibraryIfNeeded()
            }
            item("Listening", "chart.bar", isActive(.dashboard)) { model.route = .dashboard }

            Spacer()

            OutputPicker(model: model)

            if !model.engine.snapshot.signedIn {
                Button {
                    model.engine.beginSignIn()
                } label: {
                    Label("Sign in", systemImage: "person.crop.circle")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
            }

            Toggle(isOn: $model.showQueue) {
                Label("Queue", systemImage: "list.bullet").font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 186)
        .padding(6)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func isActive(_ r: Route) -> Bool {
        if case .detail = model.route, case .library = r { return true }
        return model.route == r
    }

    @ViewBuilder
    private func item(_ title: String, _ icon: String, _ active: Bool,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.14))
            }
        }
    }
}

// MARK: - Compact mode

private struct IconRail: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            LogoMark(size: 26)
                .padding(.top, 12).padding(.bottom, 4)

            tile("play.circle", "Now Playing", true) { }
            tile("magnifyingglass", "Search", false) {
                model.route = .search
                model.toggleCompact()
            }
            tile("square.stack", "Library", false) {
                model.route = .library
                model.loadLibraryIfNeeded()
                model.toggleCompact()
            }
            tile("list.bullet", "Queue", false) {
                model.showQueue = true
                model.toggleCompact()
            }
            Spacer(minLength: 4)
        }
        .frame(width: 56)
        .frame(maxHeight: 268)
        .padding(.bottom, 8)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    @ViewBuilder
    private func tile(_ icon: String, _ help: String, _ active: Bool,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.plain)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.16))
            }
        }
        .help(help)
    }
}

private struct CompactNowPlaying: View {
    @Bindable var model: AppModel

    private var engine: Engine { model.engine }
    private var snap: EngineSnapshot { engine.snapshot }
    @State private var lastNudge = Date.distantPast

    var body: some View {
        GeometryReader { geo in
            let art = min(max(geo.size.height * 0.48, 210), 400)

            ZStack {
                VStack(spacing: 24) {
                    // Video mode makes the whole window the picture, so the
                    // still and the equalizers step out of the way entirely.
                    if !model.videoMode {
                        HStack(spacing: 26) {
                            EqualizerView(palette: model.palette,
                                          isPlaying: snap.playback.isPlaying, seed: 0)
                                .frame(height: art)
                                .frame(maxWidth: .infinity)

                            Artwork(url: snap.track?.artworkURL, corner: 22)
                                .frame(width: art, height: art)
                                .shadow(color: .black.opacity(0.6), radius: 36, y: 18)
                                .onTapGesture { model.toggleCompact() }
                                .help("Click to exit compact mode")

                            EqualizerView(palette: model.palette,
                                          isPlaying: snap.playback.isPlaying, seed: 137)
                                .frame(height: art)
                                .frame(maxWidth: .infinity)
                        }
                        .transition(.opacity)
                    } else {
                        // Same reasoning as the full pane: the video is the
                        // only thing there, so it has to be what you click.
                        Color.clear
                            .frame(height: art)
                            .contentShape(Rectangle())
                            .onTapGesture { model.toggleCompact() }
                            .help("Click to exit compact mode")
                    }

                    VStack(spacing: 7) {
                        Text(snap.track?.title ?? "Nothing playing")
                            .font(.system(size: 30, weight: .bold))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(model.videoMode ? 0.75 : 0), radius: 10)
                        Text(snap.track?.artist ?? "—")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(model.videoMode ? 0.75 : 0), radius: 10)
                    }
                }
                .padding(.horizontal, 92)

                HStack { IconRail(model: model); Spacer() }
                    .padding(.leading, 16).padding(.top, 30)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(model.controlsVisible ? 1 : 0.42)

                HStack(spacing: 10) {
                    Spacer()
                    if snap.hasVideo { VideoToggle(model: model) }
                    GlassIconButton(system: "arrow.down.right.and.arrow.up.left",
                                    size: 13, diameter: 34) { model.toggleCompact() }
                        .help("Exit compact mode")
                }
                .padding(.trailing, 22).padding(.top, 30)
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(model.controlsVisible ? 1 : 0)

                VStack {
                    Spacer()
                    CompactControls(model: model)
                        .opacity(model.controlsVisible ? 1 : 0)
                        .padding(.bottom, 30)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                // Throttled: this fires per mouse-move event and each nudge
                // rebuilds a cancellation task.
                guard case .active = phase else { return }
                let now = Date()
                guard now.timeIntervalSince(lastNudge) > 0.15 else { return }
                lastNudge = now
                model.nudgeControls()
            }
        }
        .onAppear { model.nudgeControls() }
    }
}

private struct CompactControls: View {
    @Bindable var model: AppModel

    private var engine: Engine { model.engine }
    private var snap: EngineSnapshot { engine.snapshot }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                GlassIconButton(system: "shuffle", size: 13, diameter: 32,
                                active: snap.shuffled ?? false) { engine.shuffleQueue() }
                GlassIconButton(system: "backward.fill", size: 15, diameter: 36) { engine.previous() }
                GlassIconButton(system: snap.playback.isPlaying ? "pause.fill" : "play.fill",
                                size: 19, diameter: 50, prominent: true) { engine.togglePlayPause() }
                GlassIconButton(system: "forward.fill", size: 15, diameter: 36) { engine.next() }
                GlassIconButton(system: snap.repeatMode == "ONE" ? "repeat.1" : "repeat",
                                size: 13, diameter: 32,
                                active: snap.repeatMode != "NONE") { engine.cycleRepeat() }
            }
            // No collapse button here on purpose. Transport is five symmetric
            // controls around play; a sixth on the right end drags the play
            // button off centre and the whole panel reads as misaligned.

            HStack(spacing: 10) {
                Text(timeString(engine.displayTime))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 42, alignment: .trailing)
                Scrubber(value: engine.displayTime, total: snap.duration) { t in
                    engine.scrubOverride = t
                } onCommit: { t in
                    engine.seek(to: t)
                    engine.scrubOverride = nil
                }
                .frame(width: 420)
                Text(timeString(snap.duration))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 42, alignment: .leading)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}
