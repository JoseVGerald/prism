import SwiftUI

struct ContentPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.route {
            case .forYou:     ForYouPane(model: model)
            case .nowPlaying: NowPlayingPane(model: model)
            case .search:     SearchPane(model: model)
            case .library:    LibraryPane(model: model)
            case .dashboard:  DashboardPane(model: model)
            case .detail(_, let title): DetailPane(model: model, title: title)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clip before the glass so scroll content cannot escape the panel.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Glass off in video mode: the sidebar and queue stay frosted, this
        // pane goes clear, and the picture reads sharply through the middle.
        .modifier(PaneGlass(enabled: !model.videoMode))
    }
}

/// Switches a track between its song and its music video, the way YouTube
/// Music's own Song/Video control does.
///
/// Distinct from `VideoToggle`, which only chooses what Prism draws for the
/// track already loaded. This one changes which recording is playing.
struct AVToggle: View {
    @Bindable var model: AppModel

    private var showingVideo: Bool { model.engine.snapshot.showingVideoSide }

    /// Lets the selected pill travel between the two sides rather than fading
    /// out of one and into the other, so the control reads as one moving part.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 3) {
            side("Song", selected: !showingVideo) { model.setAVMode(video: false) }
            side("Video", selected: showingVideo) { model.setAVMode(video: true) }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: showingVideo)
        .help("Switch between the song and the music video")
    }

    private func side(_ label: String, selected: Bool,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(selected ? AnyShapeStyle(.primary)
                                          : AnyShapeStyle(.secondary))
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule().fill(.white.opacity(0.22))
                            .matchedGeometryEffect(id: "avPill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.94))
    }
}

/// Switches the Now Playing area between the music video and the cover art.
struct VideoToggle: View {
    @Bindable var model: AppModel

    var body: some View {
        Button { model.toggleVideoMode() } label: {
            Label(model.videoMode ? "Cover art" : "Music video",
                  systemImage: model.videoMode ? "photo" : "play.rectangle.fill")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 13).padding(.vertical, 7)
        }
        .buttonStyle(PressableButtonStyle())
        .glassEffect(.regular.interactive(), in: .capsule)
        .hoverBloom()
        .help(model.videoMode ? "Show the cover art" : "Play the music video")
    }
}

// MARK: - Now playing (big art)

private struct NowPlayingPane: View {
    @Bindable var model: AppModel
    private var track: Track? { model.engine.snapshot.track }
    private var playing: Bool { model.engine.snapshot.playback.isPlaying }

    private var snap: EngineSnapshot { model.engine.snapshot }

    /// The equalizer is the most expensive thing Prism draws, and a window
    /// nobody can see is the cheapest place to stop drawing it.
    private var animatingBars: Bool { playing && model.windowVisible }

    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 22) {
            // Settings live here rather than on For You: this is the pane the
            // ambient controls actually change, so the gear is next to its
            // effect.
            HStack {
                Spacer()
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .glassEffect(.regular.interactive(), in: .circle)
                .hoverBloom()
                .help("Settings")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    SettingsPanel(model: model)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            Spacer(minLength: 0)

            // Lyrics take the whole middle: the point of the mode is to read
            // them, not to squeeze them next to the art.
            if model.lyricsMode {
                LyricsView(model: model)
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .transition(.opacity)
            } else if !model.videoMode {
                HStack(spacing: 18) {
                    if model.ambient.showEqualizers {
                        EqualizerView(palette: model.palette, isPlaying: animatingBars,
                                      seed: 0, maxBlocks: 6, block: 5, gap: 2.5)
                            .frame(height: 240)
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }

                    Artwork(url: track?.artworkURL, corner: 18)
                        .frame(width: 240, height: 240)
                        .shadow(color: .black.opacity(0.55), radius: 34, y: 16)
                        // Keyed on the id so a new track genuinely swaps the
                        // view: the old sleeve drops back and fades while the
                        // new one rises into place, instead of one URL quietly
                        // replacing another inside the same image.
                        .id(track?.videoId)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92)),
                            removal: .opacity.combined(with: .scale(scale: 1.04))))
                        .animation(.spring(response: 0.5, dampingFraction: 0.82),
                                   value: track?.videoId)
                        .onTapGesture { model.toggleCompact() }
                        .help("Click for compact mode")

                    if model.ambient.showEqualizers {
                        EqualizerView(palette: model.palette, isPlaying: animatingBars,
                                      seed: 137, maxBlocks: 6, block: 5, gap: 2.5)
                            .frame(height: 240)
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 18)
                .transition(.opacity)
            } else {
                // No artwork to click in video mode, which otherwise leaves
                // compact mode unreachable. The picture itself is the target.
                Color.clear
                    .frame(height: 260)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleCompact() }
                    .help("Click to focus")
            }

            VStack(spacing: 10) {
                Text(track?.title ?? "Nothing playing")
                    .font(.system(size: 25, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(model.videoMode ? 0.7 : 0), radius: 8)
                Text(track?.artist ?? "Pick something to get started")
                    .font(.title3)
                    .foregroundStyle(model.videoMode ? AnyShapeStyle(.white.opacity(0.8))
                                                     : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(model.videoMode ? 0.7 : 0), radius: 8)
                HStack(spacing: 8) {
                    // A paired track gets the Song/Video switcher; a video with
                    // no song behind it only gets the cover-art toggle.
                    if snap.hasCounterpart { AVToggle(model: model) }
                    else if snap.hasVideo { VideoToggle(model: model) }
                    if track != nil { LyricsToggle(model: model) }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 40)

            if model.videoMode { Spacer().frame(height: 24) } else { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Search

private struct SearchPane: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search songs, albums, artists", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { model.runSearch() }
                    .onChange(of: model.searchText) { model.runSearch() }
                if model.searching { ProgressView().controlSize(.small) }
                if !model.searchText.isEmpty {
                    Button { model.searchText = ""; model.searchResults = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(16)

            if model.searchResults != nil || !model.searchText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SearchScope.allCases) { scope in
                            let selected = model.searchScope == scope
                            Button {
                                model.searchScope = scope
                            } label: {
                                Text(scope.label)
                                    .font(.caption.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                                    .padding(.horizontal, 13).padding(.vertical, 6)
                                    .background {
                                        Capsule().fill(selected ? AnyShapeStyle(.white)
                                                                : AnyShapeStyle(.white.opacity(0.12)))
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 10)
            }

            if let results = model.searchResults {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        // What YouTube thinks you meant, ahead of everything.
                        // Searching an album name should lead with the album,
                        // not with a track that happens to live inside it.
                        if model.searchScope == .all,
                           results.topShelf != nil || results.topTrack != nil {
                            SectionHeader("Top result")
                            if let shelf = results.topShelf {
                                TopResultCard(shelf: shelf) { model.open(shelf) }
                            } else if let track = results.topTrack {
                                TrackRow(model: model, track: track)
                            }
                        }

                        // The best songs, then everything else, then the rest of
                        // the songs. Albums used to sit below the *entire* song
                        // list — twenty-odd rows down, past the reuploads — so
                        // they may as well not have been there. The strong
                        // matches are at the top anyway after ranking, so
                        // breaking the list lets albums and artists surface
                        // without pushing anything out of reach.
                        if !results.songs.isEmpty {
                            SectionHeader("Songs")
                            ForEach(results.songs.prefix(6)) { song in
                                TrackRow(model: model, track: song)
                            }
                        }
                        shelfRow("Albums", results.albums)
                        shelfRow("Artists", results.artists)
                        shelfRow("Playlists", results.playlists)

                        if results.songs.count > 6 {
                            SectionHeader("More songs")
                            ForEach(results.songs.dropFirst(6)) { song in
                                TrackRow(model: model, track: song)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 20)
                }
            } else {
                Spacer()
                Text(model.searchText.isEmpty ? "What do you want to hear?" : "No results")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func shelfRow(_ title: String, _ items: [Shelf]) -> some View {
        if !items.isEmpty {
            SectionHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { shelf in
                        ShelfCard(shelf: shelf) { model.open(shelf) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Library

private struct LibraryPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.libraryLoading && model.library.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading your library…").foregroundStyle(.secondary)
                }
            } else if model.library.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.stack")
                        .font(.system(size: 38)).foregroundStyle(.secondary)
                    Text(model.engine.snapshot.signedIn
                         ? "Nothing in your library yet."
                         : "Sign in to load your library.")
                        .foregroundStyle(.secondary)
                    if !model.engine.snapshot.signedIn {
                        Button("Sign in") { model.engine.beginSignIn() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Retry") { model.loadLibraryIfNeeded(force: true) }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(model.library) { section in
                            SectionHeader(section.title)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 14)],
                                      spacing: 16) {
                                ForEach(section.items) { shelf in
                                    ShelfCard(shelf: shelf) { model.open(shelf) }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The pane starts its own load.
        //
        // It used to rely on whoever navigated here to call
        // `loadLibraryIfNeeded()`, and every caller was in a macOS-only file —
        // the sidebar item and the menu command. On iPhone the tab set
        // `model.route` and nothing ever asked for the data, so Library showed
        // "Nothing in your library yet" forever and only the Retry button,
        // which forces a load, ever worked. Owning the fetch here means a new
        // way of reaching the pane cannot forget to start it.
        .task { model.loadLibraryIfNeeded() }
    }
}

// MARK: - Playlist / album detail

private struct DetailPane: View {
    @Bindable var model: AppModel
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    model.closeDetail()
                } label: {
                    Image(systemName: "chevron.left").font(.callout.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)

                Artwork(url: model.detail?.artworkURL, corner: 8)
                    .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.detail?.title ?? title)
                        .font(.title3.weight(.semibold)).lineLimit(1)
                    if let sub = model.detail?.subtitle {
                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let tracks = model.detail?.tracks, !tracks.isEmpty {
                    Button {
                        model.playAll(tracks, title: model.detail?.title ?? title)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .padding(16)

            if model.detailLoading {
                Spacer(); ProgressView(); Spacer()
            } else if let detail = model.detail,
                      !detail.tracks.isEmpty || !(detail.sections ?? []).isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if !detail.tracks.isEmpty {
                            // An artist's list is their top songs, not a
                            // numbered tracklist, so the ordinals would be
                            // meaningless there.
                            if detail.kind == "artist" { SectionHeader("Top songs") }
                            VStack(spacing: 0) {
                                ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { i, t in
                                    TrackRow(model: model, track: t,
                                             ordinal: detail.kind == "artist" ? nil : i + 1)
                                }
                            }
                        }
                        // Albums, Singles & EPs, Videos — the carousels that
                        // make an artist page an artist page.
                        ForEach(detail.sections ?? []) { section in
                            SectionHeader(section.title)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(section.items) { item in
                                        ShelfCard(shelf: item) { model.open(item) }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 20)
                }
            } else {
                Spacer()
                Text("Nothing here").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }
}

// MARK: - Shared pieces

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

struct ShelfCard: View {
    let shelf: Shelf
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Artwork(url: shelf.artworkURL, corner: shelf.kind == "artist" ? 66 : 10)
                    .frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.4), radius: hovering ? 14 : 7, y: 5)
                Text(shelf.title).font(.callout.weight(.medium)).lineLimit(1)
                if let sub = shelf.subtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 132, alignment: .leading)
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.035 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// The single best match, given room to be recognised.
///
/// Wider and flatter than a `ShelfCard` so it reads as an answer rather than as
/// the first item of a row, and it names what it is — an album and an artist
/// with the same name are otherwise impossible to tell apart at a glance.
struct TopResultCard: View {
    let shelf: Shelf
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Artwork(url: shelf.artworkURL, corner: shelf.kind == "artist" ? 44 : 10)
                    .frame(width: 88, height: 88)
                    .shadow(color: .black.opacity(0.4), radius: hovering ? 14 : 7, y: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(shelf.kind.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(shelf.title).font(.title3.weight(.semibold)).lineLimit(2)
                    if let sub = shelf.subtitle {
                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .onHover { hovering = $0 }
    }
}

/// One song row with hover-revealed play / play-next / add-to-queue actions.
struct TrackRow: View {
    @Bindable var model: AppModel
    let track: Track
    var ordinal: Int? = nil

    @State private var hovering = false

    private var isCurrent: Bool { model.engine.snapshot.track?.videoId == track.videoId }

    var body: some View {
        HStack(spacing: 12) {
            // The play target is its own button rather than an onTapGesture on
            // the whole row — a row-wide tap gesture swallows clicks aimed at
            // the hover actions sitting inside it.
            Button {
                // Radio by default, so a track picked out of search leads
                // somewhere instead of stopping dead after one song.
                model.engine.play(videoId: track.videoId)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        if let ordinal, !hovering, !isCurrent {
                            Text("\(ordinal)").font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Artwork(url: track.artworkURL, corner: 6)
                        }
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(track.title)
                                .font(.callout.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor)
                                                           : AnyShapeStyle(.primary))
                                .lineLimit(1)
                            if track.explicit == true { ExplicitBadge() }
                        }
                        Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }
                                .joined(separator: " • "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Inline actions on the Mac only.
            //
            // Always laid out there, never hover-conditional: appearing only on
            // hover left the play button's tap area covering these coordinates,
            // so clicks aimed here started the track instead.
            //
            // On a phone they are dropped entirely. Three buttons plus a
            // duration left titles truncated to "Rendezv…" and "Rosary (f…" on
            // a 393pt screen, and every one of those actions is already in the
            // long-press menu below — which is the platform's own idiom, not a
            // consolation prize.
            #if canImport(AppKit)
            HStack(spacing: 6) {
                GlassIconButton(system: "text.line.first.and.arrowtriangle.forward",
                                size: 12, diameter: 28) {
                    model.enqueue(track, atEnd: false)
                }
                .help("Play next")

                GlassIconButton(system: "text.append", size: 12, diameter: 28) {
                    model.enqueue(track, atEnd: true)
                }
                .help("Add to queue")

                GlassIconButton(system: "arrow.down.circle", size: 12, diameter: 28) {
                    model.download(track)
                }
                .help("Download for offline")
            }
            .opacity(hovering ? 1 : PlatformInteraction.restingActionOpacity)
            .animation(.easeOut(duration: 0.15), value: hovering)
            #endif

            if let d = track.durationText {
                Text(d).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hovering ? 0.10 : 0))
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.13), value: hovering)
        .contextMenu {
            Button("Play radio from here") { model.engine.play(videoId: track.videoId) }
            // The escape hatch from the radio default: play exactly this and
            // nothing after it.
            Button("Play just this song") {
                model.engine.play(videoId: track.videoId, radio: false)
            }
            Divider()
            Button("Play next") { model.enqueue(track, atEnd: false) }
            Button("Add to queue") { model.enqueue(track, atEnd: true) }
            Divider()
            Button("Download") { model.download(track) }
        }
    }
}

/// YouTube's explicit marker, drawn rather than fetched.
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.black.opacity(0.75))
            .frame(width: 13, height: 13)
            .background(.secondary.opacity(0.85), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("Explicit")
    }
}
