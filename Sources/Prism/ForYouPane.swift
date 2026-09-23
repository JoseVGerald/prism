import SwiftUI

/// The landing page.
///
/// Two sources, side by side. YouTube Music's own Home feed — Quick picks,
/// your mixes, Listen again, new releases — personalised to the signed-in
/// account, fetched the way the web app fetches it. And Prism's own listening
/// log, for the things only it knows: what you have had on repeat, what you
/// used to play and haven't lately, and the stats. The feed is what makes the
/// page worth opening; the log is what makes it yours when the feed is thin.
struct ForYouPane: View {
    @Bindable var model: AppModel

    private var history: History { model.history }
    private var monthAgo: Date { Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if history.isEmpty && model.home.isEmpty && !model.homeLoading {
                    emptyState
                } else {
                    heroRow
                    // YouTube's shelves in YouTube's order — songs as a grid,
                    // everything else as cards — with On repeat after the
                    // first two, where it is seen without scrolling far.
                    ForEach(Array(model.home.prefix(2))) { shelf($0) }
                    onRepeat
                    ForEach(Array(model.home.dropFirst(2))) { shelf($0) }
                    if model.homeLoading && model.home.isEmpty { loadingShelf }
                    rediscover
                    if !model.suggestions.isEmpty || model.suggestionsLoading { suggestions }
                    if !history.isEmpty { quickStats }
                }
            }
            .padding(22)
        }
        .task(id: model.engine.snapshot.ready) {
            model.loadHome()
            model.loadSuggestions()
        }
    }

    // MARK: Header and hero

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(greeting).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(model.home.isEmpty
                     ? (history.isEmpty ? "Play something and this page fills itself in."
                                        : "Picked up from what you have actually been playing.")
                     : "Your YouTube Music picks, and what Prism has heard you play.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.loadHome(force: true)
                model.loadSuggestions(force: true)
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(model.homeLoading ? 180 : 0))
                    .animation(.easeInOut(duration: 0.5), value: model.homeLoading)
            }
            .buttonStyle(.plainHit)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Refresh")
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Still up"
        }
    }

    /// "Jump back in" to the last thing played, beside the account's own mixes.
    @ViewBuilder
    private var heroRow: some View {
        let last = history.recent(limit: 1).first
        let mixes = model.home.flatMap(\.items)
            .filter { $0.kind == .mix || ($0.kind == .playlist && $0.title.localizedCaseInsensitiveContains("mix")) }
        if last != nil || !mixes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    if let last {
                        HeroTile(title: last.title, subtitle: "Jump back in · \(last.artist)",
                                 artworkURL: last.artworkURL, symbol: "play.fill") {
                            model.engine.play(videoId: last.videoId)
                        }
                    }
                    ForEach(mixes.prefix(4)) { mix in
                        HeroTile(title: mix.title, subtitle: mix.subtitle ?? "Mix",
                                 artworkURL: mix.artworkURL, symbol: "shuffle") { model.play(mix) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LogoMark(size: 44).opacity(0.7)
            Text("Nothing here yet").font(.title3.weight(.medium))
            Text(model.engine.snapshot.signedIn
                 ? "Your YouTube Music picks will load in a moment, and Prism's own listening log fills in as you play."
                 : "Sign in for your YouTube Music picks. Prism also keeps its own listening log on \(PlatformWording.thisDevice) — nothing leaves the device.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                if !model.engine.snapshot.signedIn {
                    Button("Sign in") { model.engine.beginSignIn() }
                        .buttonStyle(.plainHit)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                Button("Find something to play") { model.route = .search }
                    .buttonStyle(.plainHit)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
    }

    // MARK: YouTube Music shelves

    @ViewBuilder
    private func shelf(_ shelf: HomeShelf) -> some View {
        if shelf.isSongs { quickPicks(shelf) } else { cards(shelf) }
    }

    private func quickPicks(_ shelf: HomeShelf) -> some View {
        section(shelf.title, subtitle: shelf.strapline ?? "Songs picked for you by YouTube Music") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(58), spacing: 2), count: 4), spacing: 10) {
                    ForEach(shelf.items) { item in
                        QuickPickRow(item: item,
                                     isCurrent: item.videoId == model.engine.snapshot.track?.videoId) {
                            model.play(item)
                        }
                        .contextMenu { songMenu(item) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func cards(_ shelf: HomeShelf) -> some View {
        section(shelf.title, subtitle: shelf.strapline) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.items) { item in
                        HomeCard(item: item) { model.play(item) }
                            .contextMenu { if item.videoId != nil { songMenu(item) } }
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 2)
            }
        }
    }

    @ViewBuilder
    private func songMenu(_ item: HomeItem) -> some View {
        if let id = item.videoId {
            let track = Track(videoId: id, title: item.title, artist: item.subtitle ?? "",
                              album: nil, durationText: nil, durationSeconds: nil,
                              artworkURL: item.artworkURL)
            Button("Play") { model.engine.play(videoId: id) }
            Button("Play next") { model.enqueue(track, atEnd: false) }
            Button("Add to queue") { model.enqueue(track, atEnd: true) }
            Button("Download") { model.download(track) }
        }
    }

    private var loadingShelf: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading your YouTube Music picks…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    // MARK: From Prism's own log

    /// What has been played most this month.
    @ViewBuilder
    private var onRepeat: some View {
        let top = history.topTracks(since: monthAgo, limit: 14).filter { $0.count >= 2 }
        if top.count >= 3 {
            section("On repeat", subtitle: "Your most played this month") {
                playCards(top.map(\.play), badges: top.map { "\($0.count) plays" })
            }
        }
    }

    /// Played a lot before this month, not at all since.
    @ViewBuilder
    private var rediscover: some View {
        let recentIds = Set(history.plays(since: monthAgo).map(\.videoId))
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast
        let older = history.topTracks(since: yearAgo, limit: 60)
            .filter { !recentIds.contains($0.play.videoId) && $0.count >= 2 }
            .prefix(14)
        if older.count >= 3 {
            section("Rediscover", subtitle: "You played these a lot — just not lately") {
                playCards(older.map(\.play), badges: nil)
            }
        }
    }

    private func playCards(_ plays: [Play], badges: [String]?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(Array(plays.enumerated()), id: \.element.id) { i, play in
                    PlayCard(play: play, badge: badges?[i]) { model.engine.play(videoId: play.videoId) }
                        .contextMenu {
                            Button("Play") { model.engine.play(videoId: play.videoId) }
                            Button("Play next") { model.enqueue(play.asTrack, atEnd: false) }
                            Button("Add to queue") { model.enqueue(play.asTrack, atEnd: true) }
                        }
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 4)
        }
    }

    private var suggestions: some View {
        section("Because you have been playing \(model.suggestionSeed)",
                subtitle: "Related tracks, not a generic chart") {
            if model.suggestionsLoading && model.suggestions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.suggestions.prefix(6)) { track in
                        TrackRow(model: model, track: track)
                    }
                }
            }
        }
    }

    private var quickStats: some View {
        section("This month", subtitle: nil) {
            HStack(spacing: 12) {
                StatTile(value: hours(history.seconds(since: monthAgo)), label: "listened")
                StatTile(value: "\(history.plays(since: monthAgo).count)", label: "plays")
                StatTile(value: "\(history.streak)", label: "day streak")
                Button {
                    model.route = .dashboard
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Image(systemName: "chart.bar.fill").font(.system(size: 15))
                        Text("Full stats").font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
                .buttonStyle(.plainHit)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 13))
            }
        }
    }

    private func hours(_ seconds: Double) -> String {
        let h = seconds / 3600
        return h >= 1 ? String(format: "%.1fh", h) : "\(Int(seconds / 60))m"
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, subtitle: String?,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
    }
}

/// A wide tile for the top of the page: art on the left, words on the right.
private struct HeroTile: View {
    let title: String
    let subtitle: String
    let artworkURL: String?
    let symbol: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Artwork(url: artworkURL, corner: 10).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(hovering ? 0.25 : 0.12)))
            }
            .padding(10)
            .frame(width: 300, alignment: .leading)
        }
        .buttonStyle(.plainHit)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .scaleEffect(hovering ? 1.02 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
    }
}

private struct PlayCard: View {
    let play: Play
    var badge: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    Artwork(url: play.artworkURL, corner: 11)
                    if hovering {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.black.opacity(0.35))
                        Image(systemName: "play.fill").font(.system(size: 20))
                    }
                }
                .frame(width: 128, height: 128)

                Text(play.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(badge.map { "\(play.artist) · \($0)" } ?? play.artist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 128, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .glassEffect(.regular, in: .rect(cornerRadius: 13))
    }
}

extension Play {
    var asTrack: Track {
        Track(videoId: videoId, title: title, artist: artist, album: nil,
              durationText: nil, durationSeconds: nil, artworkURL: artworkURL)
    }
}
