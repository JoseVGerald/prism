import SwiftUI

/// One shelf of YouTube Music's Home feed: "Quick picks", "Mixed for you",
/// "Listen again", "New releases" and the rest, personalised to the account.
struct HomeShelf: Codable, Identifiable, Hashable {
    var title: String
    /// The small line YouTube puts above some titles ("Start radio from a song").
    var strapline: String?
    var items: [HomeItem]

    var id: String { title }
    /// Quick picks and the like: a shelf of songs rather than of cards.
    var isSongs: Bool { items.count >= 4 && items.allSatisfy { $0.kind == .song } }
}

struct HomeItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case song, video, album, playlist, artist, mix }

    var kind: Kind
    var title: String
    var subtitle: String?
    var artworkURL: String?
    var videoId: String?
    var browseId: String?
    var playlistId: String?

    var id: String { videoId ?? browseId ?? playlistId ?? title }

    /// The song, for anything that plays or queues songs; nil for an album,
    /// playlist, artist or mix.
    var asTrack: Track? {
        guard let videoId, kind == .song || kind == .video else { return nil }
        return Track(videoId: videoId, title: title, artist: subtitle ?? "", album: nil,
                     durationText: nil, durationSeconds: nil, artworkURL: artworkURL)
    }

    var asShelf: Shelf? {
        browseId.map { Shelf(browseId: $0, title: title, subtitle: subtitle,
                             artworkURL: artworkURL, kind: kind.rawValue) }
    }
}

// MARK: - Cards

/// A square card for an album, playlist, mix or video; round for an artist.
struct HomeCard: View {
    let item: HomeItem
    var size: CGFloat = 150
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 7) {
                ZStack {
                    if item.kind == .artist {
                        Artwork(url: item.artworkURL, corner: size / 2)
                    } else {
                        Artwork(url: item.artworkURL, corner: 12)
                    }
                    if hovering {
                        Circle().fill(.black.opacity(0.45)).frame(width: 44, height: 44)
                        Image(systemName: item.kind == .artist ? "arrow.right" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.2), radius: hovering ? 12 : 6, y: 4)
                .scaleEffect(hovering ? 1.03 : 1)

                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(width: size, alignment: item.kind == .artist ? .center : .leading)
        }
        .buttonStyle(.plainHit)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
    }
}

/// A compact song row for the Quick picks grid.
struct QuickPickRow: View {
    let item: HomeItem
    var isCurrent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    Artwork(url: item.artworkURL, corner: 6)
                    if hovering || isCurrent {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.4))
                        Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(item.subtitle ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: 290, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plainHit)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
