import SwiftUI
import WebKit

/// The phone shell.
///
/// Everything below the surface is the macOS app unchanged — `AppModel`,
/// `Engine`, the bridge, the queue, history, AutoMix. What is rebuilt is the
/// arrangement, because the desktop one does not survive a phone: a sidebar
/// becomes a tab bar, a side-by-side queue becomes a sheet, and a transport
/// that appears on hover becomes one that is simply always there.
struct IOSRootView: View {
    @Bindable var model: AppModel

    @State private var tab: Route = .forYou
    /// One sheet at a time, chosen by identity.
    ///
    /// Two separate `isPresented` bindings on the same view cannot both work:
    /// SwiftUI presents only one sheet per view, so the queue button inside the
    /// player sheet — which set its flag and then dismissed — silently did
    /// nothing. The dismissal had not finished before the second presentation
    /// was requested, so the request was dropped. A single piece of state makes
    /// swapping one sheet for another explicit instead of a race.
    enum Sheet: String, Identifiable {
        case player, queue
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?
    @State private var drive: DebugDrive?

    private var engine: Engine { model.engine }
    private var snap: EngineSnapshot { engine.snapshot }

    /// The webview is showing the picture rather than acting as a hidden engine.
    private var showingVideo: Bool { model.videoMode && !engine.showingEngine }

    /// A phone held sideways. Video mode is designed for it.
    @Environment(\.verticalSizeClass) private var vSize

    /// How far the webview is blown up in video mode so the picture bleeds off
    /// every edge of the phone.
    ///
    /// This is a measured constant, not a derived one, and it is worth saying
    /// why rather than leaving it looking like a magic number.
    ///
    /// WebKit's media layer does not paint into the box CSS gives it. Pinned to
    /// the viewport with `position: fixed; width: 100vw; height: 100dvh;
    /// object-fit: cover`, the `<video>` element measures exactly 874x402 —
    /// the whole viewport — and the compositor still painted the picture at
    /// 801x219, centred, with the backdrop showing all round it. The page is
    /// not the problem: a magenta probe drawn by the page at those same
    /// `100vw x 100dvh` bounds spanned the screen edge to edge, so the page
    /// maps 1:1 and it is the video layer alone that under-fills.
    ///
    /// Nothing in the page reports where that layer actually lands, so there is
    /// no measurement to derive a factor from. 402/219 is what it takes to
    /// cover the short edge; the rest is margin.
    ///
    /// If a future WebKit starts honouring the box, this will over-crop and
    /// should go back to 1. The check is one screenshot in landscape.
    ///
    /// Landscape only. A 16:9 video cannot fill a 19.5:9 screen without
    /// throwing most of the frame away — measured, portrait needs about 4.2x
    /// and what survives is an unwatchable close-up. Held upright the picture
    /// keeps its natural width and the controls sit below it, which is what
    /// every phone video player does.
    private var videoBleed: CGFloat { vSize == .compact ? 2.6 : 1 }

    var body: some View {
        ZStack {
            // The engine's webview, mounted full-size for the whole session.
            //
            // This is load-bearing and must not be "optimised" into a hidden
            // or zero-sized view: WebKit suspends media in views that are
            // detached or have no area, and iOS is stricter about it than
            // macOS. It is covered by the backdrop rather than hidden, which
            // is the same arrangement the Mac app uses and for the same reason.
            // Behind the webview in video mode, so anything the video layer
            // leaves uncovered shows blurred artwork rather than black.
            if showingVideo {
                Backdrop(url: snap.track?.artworkURL).ignoresSafeArea()
            }

            // The webview is normally the invisible engine. It becomes visible
            // for two things, and in both cases it is the *same* view rather
            // than a second one presented elsewhere — re-parenting a WKWebView
            // suspends its media, which is the trap this whole app is built
            // around avoiding.
            //
            //  * Signing in: the real YouTube page has to be reachable.
            //  * Video mode: the page is restyled so the <video> fills the
            //    viewport, and on a phone the webview already *is* the
            //    viewport, so no measured placement is needed — the macOS
            //    build has to move and resize the view to make the picture
            //    cover a window that is a different shape to the page.
            // Order matters: the safe-area escape has to happen *before* the
            // scale, or the transform is applied and then the layout is
            // re-established around it and the scale is visually lost.
            EngineWebViewHost(webView: engine.webView)
                // The keyboard must not move this view.
                //
                // Tapping the email field on the sign-in page killed the app:
                // an NSException out of `-[__NSArrayM insertObject:atIndex:]`
                // inside `-[UIGestureRecognizer _delayTouchesForEvent:inPhase:]`,
                // i.e. UIKit's gesture machinery losing track of a touch that
                // was still in flight. The cause is SwiftUI's keyboard
                // avoidance: the keyboard appears, the safe area changes, the
                // hierarchy around the webview is re-laid-out mid-touch.
                //
                // The webview does its own scrolling to keep a focused field
                // visible, so it never wanted the avoidance in the first place.
                //
                // This was reachable only after sign-in started loading a page
                // with a text field on it — the bug is older than that change,
                // it just had nothing to type into before.
                .ignoresSafeArea(.keyboard)
                .ignoresSafeArea(.container, edges: model.videoMode ? .all : [])
                .scaleEffect(showingVideo ? videoBleed : 1, anchor: .center)
                // No `.clipped()`. It clips to the *layout* frame, which is
                // not the whole screen even with the safe area escaped, and it
                // left a 21pt strip of backdrop down one long edge that no
                // amount of extra scale would close — the strip stayed exactly
                // 48px at 1.9x, 2.5x and 2.8x, which is what gave it away.
                // Nothing needs clipping here: the overlay draws above and the
                // backdrop below.
                .opacity(engine.showingEngine || model.videoMode ? 1 : 0.001)
                .allowsHitTesting(engine.showingEngine)
                .zIndex(engine.showingEngine ? 10 : 0)

            if !engine.showingEngine {
                if model.videoMode {
                    // Video mode takes the whole screen and leaves the TabView
                    // out of it entirely.
                    //
                    // The webview cannot simply sit behind the tabs: a TabView
                    // paints an opaque background over anything under it, which
                    // is what made video mode render black while the frames
                    // were demonstrably decoding (1015 -> 1053 in three
                    // seconds, none dropped). Rather than fight that layering,
                    // the tabs step aside — which is what a phone should do
                    // with a video anyway.
                    //
                    // What is drawn instead is the ordinary player with the
                    // picture standing in for the cover art. It is the same
                    // view, so the transport cannot drift from the one in the
                    // rest of the app, and the picture gets a reserved slot in
                    // the layout rather than floating loose behind controls.
                    IOSNowPlaying(model: model, sheet: $sheet)
                } else {
                    content
                }
            }

            if engine.showingEngine { IOSSignInChrome(engine: engine) }

        }
        // .task(id:) rather than .onChange, for the same reason as on macOS:
        // a track is usually already playing when the view appears and
        // .onChange never fires for it.
        .task(id: snap.track?.artworkURL) {
            model.refreshPalette(for: snap.track?.artworkURL)
        }
        // One funnel for everything that reacts to engine state — the listening
        // log, the Now Playing tile, crossfade timing, lyrics.
        .onChange(of: snap.currentTime) { _, _ in model.onSnapshot(snap) }
        .onChange(of: snap.track?.videoId) { _, _ in model.onSnapshot(snap) }
        // The video stage *is* the player, so a player sheet on top of it is
        // two players — which is exactly what it looked like: YouTube's page
        // chrome at the top of the screen, a letterboxed band in the middle,
        // and a second transport in a sheet across the bottom.
        .onChange(of: model.videoMode) { _, on in if on { sheet = nil } }
        .animation(.easeInOut(duration: 0.22), value: model.status)
        .sheet(item: $sheet) { which in
            switch which {
            case .player:
                IOSPlayerSheet(model: model, sheet: $sheet)
            case .queue:
                // No navigation title: QueuePanel draws its own header with
                // the count, shuffle, clear and undo controls, so a bar title
                // above it just says "Queue" twice.
                QueuePanel(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .overlay(alignment: .top) { statusToast }
        // Verification hook; does nothing unless PRISM_EVAL=1. See DebugDrive.
        .task {
            guard drive == nil else { return }
            let d = DebugDrive(model: model) { what in
                sheet = what == "player" ? .player : .queue
            }
            drive = d
            d.startIfEnabled()
        }
    }

    private var content: some View {
        // The mini player is the TabView's *bottom accessory*, which is the
        // iOS 26 slot built for exactly this and the only arrangement of the
        // three tried that does not collide with the tab bar.
        //
        //  * As a sibling in a VStack it drew below the bar, off the bottom of
        //    the screen.
        //  * As a `safeAreaInset(edge: .bottom)` it drew *over* the bar. An
        //    inset is applied at the TabView's own bottom edge, and in iOS 26
        //    the tab bar is a floating glass capsule inside that edge rather
        //    than a strip below it — so the inset and the bar were handed the
        //    same band of screen and the player sat on the labels.
        //
        // The accessory slot is above the bar by construction, supplies its own
        // glass, and shrinks the pages by the right amount. It also collapses
        // into the bar when the bar minimises on scroll, which is why the
        // player below reads `tabViewBottomAccessoryPlacement` rather than
        // drawing one fixed size.
        TabView(selection: $tab) {
                ForEach(Self.tabs, id: \.route) { entry in
                    pane
                        .tabItem { Label(entry.title, systemImage: entry.icon) }
                        .tag(entry.route)
                }
            }
        .onChange(of: tab) { _, new in
            // The tab bar drives the same `route` the Mac sidebar does, so
            // every pane below works untouched. A detail page pushed on top
            // of a tab keeps its own back stack.
            if case .detail = model.route, new == model.detailOrigin { return }
            model.route = new
        }
        .onChange(of: model.route) { _, new in
            if case .detail = new {} else { tab = new }
        }
        // `isEnabled:` rather than an empty accessory body. The slot is
        // reserved whatever the content is, so returning nothing left an empty
        // glass capsule floating above the tab bar with nothing playing.
        .tabViewBottomAccessory(isEnabled: snap.track != nil && model.route != .nowPlaying) {
            IOSMiniPlayer(model: model) { tab = .nowPlaying; model.route = .nowPlaying }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // The tab bar and the pane are driven by two pieces of state, and they
        // disagreed at launch: the bar started on For You and the pane on
        // `AppModel.route`, which is Now Playing. The phone lands on For You,
        // because a player with nothing in it is a poor first screen.
        .task {
            if model.route == .nowPlaying, snap.track == nil { model.route = .forYou }
            if case .detail = model.route {} else { tab = model.route }
        }
    }

    /// One pane, chosen by `model.route` rather than by the tab, so opening an
    /// album from search replaces the pane instead of leaving the tab behind.
    /// Each tab page carries the backdrop itself.
    ///
    /// A `TabView` paints an opaque background of its own over anything behind
    /// it in the enclosing `ZStack`, which is why the app rendered flat black
    /// everywhere except inside a presented sheet — the sheet is not in the
    /// TabView, so there the gradient showed fine. Putting the backdrop inside
    /// the page puts it above that background instead of under it.
    private var pane: some View {
        // A background, not a ZStack sibling. A sibling that ignores the safe
        // area expands the stack to the whole screen and every other child is
        // laid out against that — which is how the lyrics ended up drawn
        // behind the Dynamic Island. As a background it still paints full
        // bleed and takes no part in the layout.
        paneContent
            .background {
                // Not in video mode: the webview *is* the background then, and
                // a backdrop on top of it would hide the picture entirely.
                if !model.videoMode {
                    Backdrop(url: snap.track?.artworkURL).ignoresSafeArea()
                }
            }
    }

    @ViewBuilder
    private var paneContent: some View {
        if model.route == .nowPlaying {
            // The Mac's Now Playing pane is 240pt of artwork flanked by two
            // equalizers — a shape that only exists on a wide window. The phone
            // gets the same player used by the sheet.
            IOSNowPlaying(model: model, sheet: $sheet)
        } else {
            ContentPane(model: model)
                .padding(.horizontal, 10)
                .padding(.top, 6)
        }
    }

    private static let tabs: [(route: Route, title: String, icon: String)] = [
        (.nowPlaying, "Playing", "play.circle"),
        (.forYou, "For You", "sparkles"),
        (.search, "Search", "magnifyingglass"),
        (.library, "Library", "square.stack"),
        (.dashboard, "Listening", "chart.bar")
    ]

    @ViewBuilder
    private var statusToast: some View {
        if let status = model.status {
            Text(status)
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.status = nil }
        }
    }
}

/// The bar above the tab bar. Tapping it opens the full player.
///
/// Drawn as the TabView's bottom accessory, so it does *not* supply its own
/// glass or outer padding — the slot does both, and adding a second capsule
/// inside the first looked like a bar inside a bar.
struct IOSMiniPlayer: View {
    @Bindable var model: AppModel
    let expand: () -> Void

    /// `.inline` once the tab bar has minimised on scroll: the accessory is
    /// then a strip inside the bar with room for a title and one button, and
    /// everything else has to go rather than be squeezed.
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var snap: EngineSnapshot { model.engine.snapshot }
    private var inline: Bool { placement == .inline }

    var body: some View {
        HStack(spacing: inline ? 8 : 11) {
            if !inline {
                Artwork(url: snap.track?.artworkURL, corner: 7)
                    .frame(width: 38, height: 38)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(snap.track?.title ?? "")
                    .font(inline ? .footnote.weight(.medium) : .callout.weight(.medium))
                    .lineLimit(1)
                if !inline {
                    Text(snap.track?.artist ?? "").font(.caption2)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)

            Button { model.engine.togglePlayPause() } label: {
                Image(systemName: snap.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            if !inline {
                Button { model.engine.next() } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
        .overlay(alignment: .bottom) {
            // A hairline of progress, so the bar says where you are without
            // costing any height.
            if !inline {
                GeometryReader { geo in
                    let fraction = snap.duration > 0 ? model.engine.displayTime / snap.duration : 0
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * fraction, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
        }
    }
}

/// The player, used both as the Now Playing tab and as the sheet the mini
/// player expands into. One implementation so the two cannot drift apart.
struct IOSNowPlaying: View {
    @Bindable var model: AppModel
    @Binding var sheet: IOSRootView.Sheet?
    /// The sheet needs a grabber; the tab does not.
    var showsGrabber = false

    @State private var showingTransitions = false

    private var engine: Engine { model.engine }
    private var snap: EngineSnapshot { engine.snapshot }

    var body: some View {
        // The backdrop is a *background*, not a sibling in a ZStack.
        //
        // As a sibling that ignores the safe area it expanded the enclosing
        // stack to the whole screen, and the player was then laid out against
        // that — so its content ran under the status bar and the Dynamic
        // Island. Cover art hid it, being centred between two spacers and
        // never reaching the top edge; lyrics fill their space, so the top two
        // lines were drawn behind the island.
        //
        // `.safeAreaPadding(.top)` does not fix this, which is worth knowing:
        // by then the inset has already been consumed, so there is nothing
        // left to pad by. As a background the backdrop still paints full
        // bleed and no longer takes part in the layout at all.
        Group {
            if model.videoMode {
                // A video gets its own arrangement, not the cover-art one with
                // the picture swapped in. See IOSVideoOverlay.
                IOSVideoOverlay(model: model, sheet: $sheet,
                                showingTransitions: $showingTransitions)
            } else {
            VStack(spacing: 18) {
                if showsGrabber {
                    Capsule().fill(.secondary.opacity(0.5))
                        .frame(width: 38, height: 5).padding(.top, 8)
                }

                if model.lyricsMode {
                    // Kept out of the status bar and the Dynamic Island.
                    //
                    // The pane is positioned correctly — measured, it starts at
                    // y=62 — but it is *also* handed a 62pt top safe-area
                    // inset, and a ScrollView honours that by drawing its
                    // content up through it. That is right for a list you
                    // scroll under a translucent bar and wrong for lyrics,
                    // which are opaque text on a plain backdrop: the top two
                    // lines were simply printed across the island.
                    LyricsView(model: model)
                        .safeAreaPadding(.top)
                        // Padding alone does not settle it. A ScrollView will
                        // always draw its content through whatever space it is
                        // given, so a line scrolling up eventually reaches the
                        // island however far down the frame starts — measured
                        // twice, moved down and still legible across it.
                        //
                        // Fading the top edge fixes it for good and is what a
                        // lyric sheet should look like anyway: lines arrive out
                        // of nothing rather than sliding out from under a bar.
                        .mask {
                            LinearGradient(
                                stops: [.init(color: .clear, location: 0),
                                        .init(color: .black, location: 0.13),
                                        .init(color: .black, location: 1)],
                                startPoint: .top, endPoint: .bottom)
                        }
                } else if model.videoMode {
                    // The picture is the webview, sitting untransformed at the
                    // top of the screen behind this view. Nothing is drawn for
                    // it and nothing is measured: the page's containers are all
                    // transparent in video mode, so the only thing it paints is
                    // the video itself and Prism's backdrop fills the rest.
                    //
                    // The space is reserved with a plain flexible spacer rather
                    // than a sized slot, because a sized slot would have to
                    // agree with where the picture actually lands — and page
                    // coordinates do not map to points on a phone (see the note
                    // in Bridge.setVideoMode).
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Artwork(url: snap.track?.artworkURL, corner: 16)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                        .padding(.horizontal, 34)
                    Spacer(minLength: 0)
                }

                VStack(spacing: 6) {
                    Text(snap.track?.title ?? "Nothing playing")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center).lineLimit(2)
                        .shadow(color: .black.opacity(model.videoMode ? 0.75 : 0), radius: 8)
                    Text(snap.track?.artist ?? "Pick something to get started")
                        .font(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(1)
                    if snap.hasVideo { VideoToggle(model: model).padding(.top, 2) }
                }
                .padding(.horizontal, 24)

                HStack(spacing: 8) {
                    Text(Self.time(engine.displayTime))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Scrubber(value: engine.displayTime, total: snap.duration) { t in
                        engine.scrubOverride = t
                    } onCommit: { t in
                        engine.seek(to: t)
                        engine.scrubOverride = nil
                    }
                    Text(Self.time(snap.duration))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)

                transport

                HStack(spacing: 26) {
                    LyricsToggle(model: model)
                    // Swap the presented sheet rather than dismissing and
                    // presenting, which SwiftUI drops.
                    Button { sheet = .queue } label: {
                        Image(systemName: "list.bullet").font(.body)
                    }
                    .buttonStyle(.plain)
                    // iOS cannot set the system output device — that belongs to
                    // Control Centre and AirPlay — so this is the route picker
                    // rather than the Mac's own device list.
                    AirPlayRoutePicker().frame(width: 30, height: 30)
                    Button { showingTransitions = true } label: {
                        Image(systemName: model.transitions.autoMix && Transitions.isSupported
                              ? "waveform.path.ecg" : "waveform.path")
                            .font(.body)
                            .foregroundStyle(Transitions.isSupported && model.transitions.seconds > 0
                                             ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.primary))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 18)
            }
            }
        }
        .background {
            // Not in video mode: the picture behind is the video itself, and
            // a backdrop over it would hide the very thing just switched to.
            if !model.videoMode {
                Backdrop(url: snap.track?.artworkURL).ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showingTransitions) {
            IOSTransitionsSheet(model: model)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var transport: some View {
        HStack(spacing: 30) {
            Button { engine.shuffleQueue() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(snap.shuffled == true ? AnyShapeStyle(Color.accentColor)
                                                           : AnyShapeStyle(.primary))
            }
            Button { engine.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: snap.playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 62))
            }
            Button { engine.next() } label: { Image(systemName: "forward.fill").font(.title2) }
            Button { engine.cycleRepeat() } label: {
                Image(systemName: snap.repeatMode == "ONE" ? "repeat.1" : "repeat")
                    .foregroundStyle(snap.repeatMode == "NONE" || snap.repeatMode == nil
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
            }
        }
        .buttonStyle(.plain)
    }
}

/// Thin wrapper so the mini player's sheet and the Now Playing tab are the
/// same screen.
struct IOSPlayerSheet: View {
    @Bindable var model: AppModel
    @Binding var sheet: IOSRootView.Sheet?

    var body: some View {
IOSNowPlaying(model: model, sheet: $sheet, showsGrabber: true)
    }
}

/// Sits over the webview while it is showing the real YouTube page for sign-in.
///
/// The macOS build has the same thing; without it on iOS the Library's "Sign
/// in" button set `engine.showingEngine` and nothing anywhere was listening, so
/// the button did nothing at all.
struct IOSSignInChrome: View {
    let engine: Engine

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Text("Sign in to YouTube Music, then come back.")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Button("Done") { engine.endSignIn() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 12)
            Spacer()
        }
        .zIndex(20)
    }
}

/// What Prism draws over a music video.
///
/// Deliberately not the cover-art player with the picture swapped in. That is
/// what it used to be, and in landscape it was unusable: a portrait stack of
/// title, artwork slot, scrubber and transport squeezed into 402pt of height,
/// every row on top of the picture and each other.
///
/// A video is watched in landscape, so this is designed for landscape first —
/// controls pushed to the edges, nothing in the middle, and a scrim only where
/// there is text to read. Portrait gets the same arrangement with more room.
struct IOSVideoOverlay: View {
    @Bindable var model: AppModel
    @Binding var sheet: IOSRootView.Sheet?
    @Binding var showingTransitions: Bool

    /// `.compact` height is a phone held sideways.
    @Environment(\.verticalSizeClass) private var vSize
    private var landscape: Bool { vSize == .compact }

    private var engine: Engine { model.engine }
    private var snap: EngineSnapshot { engine.snapshot }

    var body: some View {
        ZStack {
            // Only where something is written, so the middle of the picture is
            // never dimmed. Top carries the title, bottom the transport.
            LinearGradient(
                stops: [.init(color: .black.opacity(0.55), location: 0),
                        .init(color: .clear, location: 0.28),
                        .init(color: .clear, location: 0.58),
                        .init(color: .black.opacity(0.7), location: 1)],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                footer
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.track?.title ?? "")
                    .font(landscape ? .headline : .title3.weight(.semibold))
                    .lineLimit(1)
                Text(snap.track?.artist ?? "")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.8), radius: 6)

            Spacer(minLength: 8)

            Button { model.toggleVideoMode() } label: {
                Label("Cover art", systemImage: "photo")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, landscape ? 24 : 18)
        .padding(.top, landscape ? 10 : 14)
    }

    /// Scrubber and transport on one line in landscape, stacked in portrait.
    ///
    /// In landscape there is no height to spend on a separate row for each, and
    /// the width to put them side by side is exactly what a phone on its side
    /// has too much of.
    private var footer: some View {
        VStack(spacing: landscape ? 6 : 12) {
            if landscape {
                HStack(spacing: 16) {
                    transport
                    scrubber
                    secondary
                }
            } else {
                scrubber
                transport
                secondary
            }
        }
        .padding(.horizontal, landscape ? 24 : 20)
        .padding(.bottom, landscape ? 10 : 20)
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(Self.time(engine.displayTime))
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            Scrubber(value: engine.displayTime, total: snap.duration) { t in
                engine.scrubOverride = t
            } onCommit: { t in
                engine.seek(to: t)
                engine.scrubOverride = nil
            }
            Text(Self.time(snap.duration))
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
        }
    }

    private var transport: some View {
        HStack(spacing: landscape ? 20 : 30) {
            Button { engine.previous() } label: {
                Image(systemName: "backward.fill").font(.title3)
            }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: snap.playback.isPlaying
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: landscape ? 42 : 62))
            }
            Button { engine.next() } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.6), radius: 5)
    }

    private var secondary: some View {
        HStack(spacing: landscape ? 18 : 26) {
            LyricsToggle(model: model)
            Button { sheet = .queue } label: {
                Image(systemName: "list.bullet").font(.body)
            }
            .buttonStyle(.plain)
            AirPlayRoutePicker().frame(width: 28, height: 28)
            Button { showingTransitions = true } label: {
                Image(systemName: "waveform.path").font(.body)
            }
            .buttonStyle(.plain)
        }
        .shadow(color: .black.opacity(0.6), radius: 5)
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Transitions on iPhone.
///
/// This exists because the alternative was silence. `Transitions` carries an
/// `unsupportedReason` written specifically so an iOS user could be told why
/// crossfade is off — and nothing anywhere read it, so on a phone AutoMix was
/// not disabled-with-an-explanation, it was simply invisible. That contradicts
/// the rule the feature was built on: off, and says why, rather than running
/// and sounding broken.
///
/// The planner is not vestigial either — `AutoMixCore` compiles into this
/// binary and its 81 assertions pass here. What is missing on iOS is only the
/// gain control needed to *execute* a blend, so that is what the sheet says.
struct IOSTransitionsSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transitions")
                .font(.title3.weight(.semibold))
                .padding(.top, 18)

            if let reason = Transitions.unsupportedReason, !reason.isEmpty {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Crossfade is unavailable on iPhone")
                            .font(.callout.weight(.medium))
                        Text(reason)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Tempo control does work here, so AutoMix's timing "
                             + "and beat-matching would return if a way to change "
                             + "gain ever appears.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 13))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Crossfade").font(.callout)
                        Spacer()
                        Text(model.transitions.seconds > 0
                             ? "\(Int(model.transitions.seconds))s" : "Off")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { model.transitions.seconds },
                                          set: { v in
                                              let r = v.rounded()
                                              model.transitions.seconds =
                                                  r <= 0 ? 0 : max(r, Transitions.minimumBlend)
                                          }),
                           in: 0...16, step: 1)
                    Toggle("AutoMix", isOn: Binding(get: { model.transitions.autoMix },
                                                    set: { model.transitions.autoMix = $0 }))
                        .font(.callout)
                    Text(Transitions.modeNote)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 13))
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
