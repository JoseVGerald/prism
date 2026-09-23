import SwiftUI
import Observation

/// One song Prism asked YouTube to download.
struct DownloadRecord: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        /// YouTube accepted the request. It sends no confirmation, so this is
        /// as far as anyone can honestly say.
        case requested
        /// This account or item has no download action.
        case unavailable
        case failed
        /// The download was cancelled on YouTube from here.
        case removed
    }

    var videoId: String
    var title: String
    var artist: String
    var artworkURL: String?
    var requestedAt: Date
    var status: Status
    /// YouTube's reason, when it gave one.
    var note: String?

    var id: String { videoId }
}

/// Every download asked for from Prism, newest first, kept on this Mac.
///
/// A local record because there is nothing to read back: YouTube keeps
/// offline copies in its phone app, and the web client's downloads page —
/// `FEmusic_offline`, measured on a signed-in account — comes back as an empty
/// shell with no items. So this lists what was asked for and what YouTube
/// said, rather than pretending to know what is on the phone.
@MainActor
@Observable
final class DownloadLog {
    private(set) var records: [DownloadRecord] = []
    private let key = "prism.downloads"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            records = saved
        }
    }

    func note(_ record: DownloadRecord) {
        records.removeAll { $0.videoId == record.videoId }
        records.insert(record, at: 0)
        save()
    }

    func set(_ videoId: String, _ status: DownloadRecord.Status, note: String? = nil) {
        guard let i = records.firstIndex(where: { $0.videoId == videoId }) else { return }
        records[i].status = status
        records[i].note = note
        save()
    }

    func forget(_ videoId: String) {
        records.removeAll { $0.videoId == videoId }
        save()
    }

    func forgetAll() {
        records.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - The page

struct DownloadsPane: View {
    @Bindable var model: AppModel

    private var records: [DownloadRecord] { model.downloads.records }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if records.isEmpty {
                    empty
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(records) { DownloadRow(model: model, record: $0) }
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloads").font(.system(size: 26, weight: .bold))
                Text("Songs you've asked to download. YouTube keeps the offline copies "
                     + "in the YouTube Music app on your phone (Premium) — the web player "
                     + "can't list them, so this is Prism's own record.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            Spacer()
            if !records.isEmpty {
                Button("Clear list") { model.downloads.forgetAll() }
                    .buttonStyle(.plainHit)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
            Text("Nothing downloaded yet").font(.headline)
            Text("Right-click a song, or use the download button on a track or in the "
                 + "queue, and it shows up here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

private struct DownloadRow: View {
    @Bindable var model: AppModel
    let record: DownloadRecord
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.engine.play(videoId: record.videoId)
            } label: {
                HStack(spacing: 12) {
                    Artwork(url: record.artworkURL, corner: 6).frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(record.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
            }
            .buttonStyle(.plainHit)
            .help("Play")

            status
            Text(record.requestedAt, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .trailing)

            Menu {
                if record.status == .requested {
                    Button("Cancel download on YouTube") { model.removeDownload(record) }
                } else {
                    Button("Try again") {
                        model.download(videoId: record.videoId, title: record.title,
                                       artist: record.artist, artworkURL: record.artworkURL)
                    }
                }
                Button("Remove from this list") { model.downloads.forget(record.videoId) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plainHit)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.45)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(hovering ? 0.07 : 0)))
        .onHover { hovering = $0 }
        .help(record.note ?? "")
    }

    private var status: some View {
        let (text, colour): (String, Color) = switch record.status {
        case .requested:   ("Requested", .green)
        case .unavailable: ("Not available", .orange)
        case .failed:      ("Failed", .red)
        case .removed:     ("Cancelled", .secondary)
        }
        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(colour)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(colour.opacity(0.14)))
    }
}
