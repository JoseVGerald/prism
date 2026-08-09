import SwiftUI

/// The landing page: what you have been listening to, and what to play next.
///
/// Everything here comes from Prism's own log — YouTube's `FEmusic_history`
/// feed returns nothing through the web API on this account, so the page is
/// honest about being empty on day one rather than inventing filler.
struct ForYouPane: View {
    @Bindable var model: AppModel

    private var history: History { model.history }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if history.isEmpty {
                    emptyState
                } else {
                    recentlyPlayed
                    if !model.suggestions.isEmpty || model.suggestionsLoading { suggestions }
                    quickStats
                }
            }
            .padding(22)
        }
        .task { model.loadSuggestions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(greeting).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(history.isEmpty
                 ? "Play something and this page fills itself in."
                 : "Picked up from what you have actually been playing.")
                .font(.callout).foregroundStyle(.secondary)
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            LogoMark(size: 44).opacity(0.7)
            Text("Nothing logged yet").font(.title3.weight(.medium))
            Text("Prism keeps its own listening log on \(PlatformWording.thisDevice). It starts the first time you press play, and nothing leaves the device.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Find something to play") { model.route = .search }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
    }

    // MARK: Sections

    private var recentlyPlayed: some View {
        section("Recently played", subtitle: "\(history.recent(limit: 200).count) tracks in your log") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(history.recent(limit: 18)) { play in
                        PlayCard(play: play) { model.engine.play(videoId: play.videoId) }
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
                let since = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
                StatTile(value: hours(history.seconds(since: since)), label: "listened")
                StatTile(value: "\(history.plays(since: since).count)", label: "plays")
                StatTile(value: "\(history.streak)", label: history.streak == 1 ? "day streak" : "day streak")
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
                .buttonStyle(.plain)
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

private struct PlayCard: View {
    let play: Play
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
                Text(play.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 128, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
