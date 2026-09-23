import SwiftUI

/// Your listening stats, available every day of the year rather than once in
/// December. Built entirely from Prism's local log.
struct DashboardPane: View {
    @Bindable var model: AppModel

    enum Window: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", year = "12 months", all = "All time"
        var id: String { rawValue }

        var since: Date {
            let cal = Calendar.current
            switch self {
            case .week:  return cal.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            case .month: return cal.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            case .year:  return cal.date(byAdding: .month, value: -12, to: Date()) ?? .distantPast
            case .all:   return .distantPast
            }
        }
        var days: Int {
            switch self { case .week: 7; case .month: 30; case .year: 90; case .all: 90 }
        }
    }

    @State private var window: Window = .month

    private var history: History { model.history }
    private var since: Date { window.since }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Title beside the range picker on a Mac, stacked above it on a
                // phone. The picker used to be pinned to 320pt, which is wider
                // than a phone's content area — the row could not fit both, so
                // the title was squeezed to a few points and rendered one
                // letter per line down the left edge.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Listening")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .fixedSize()
                        Spacer(minLength: 12)
                        rangePicker.frame(width: 320)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Listening")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .fixedSize()
                        rangePicker
                    }
                }

                if history.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar").font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("No listening logged yet").font(.title3.weight(.medium))
                        Text("Stats build up as you play. To fill in the past, import your Google Takeout history below — it covers every device you have listened on, going back years.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                } else {
                    tiles
                    activity
                    // Side by side on a window, stacked on a phone.
                    //
                    // Two columns in 402pt leaves each about 180, and by the
                    // time "Most played" has spent that on a rank, artwork and
                    // a play count there is nothing left for the title — every
                    // row read "G…", "Ri…", "…". `ViewThatFits` picks the
                    // horizontal arrangement only where it actually fits, so
                    // the Mac is unchanged.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            artists.frame(minWidth: 260)
                            tracks.frame(minWidth: 260)
                        }
                        VStack(alignment: .leading, spacing: 22) {
                            artists
                            tracks
                        }
                    }
                }

                StatsSources(model: model)
            }
            .padding(22)
        }
    }

    private var rangePicker: some View {
        Picker("", selection: $window) {
            ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var tiles: some View {
        HStack(spacing: 12) {
            StatTile(value: hours(history.seconds(since: since)), label: "listened")
            StatTile(value: "\(history.plays(since: since).count)", label: "plays")
            StatTile(value: "\(Set(history.plays(since: since).map(\.artist)).count)", label: "artists")
            StatTile(value: "\(history.streak)", label: "day streak")
        }
    }

    private var activity: some View {
        let data = history.daily(days: window.days)
        let peak = max(data.map(\.seconds).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 9) {
            Text("Daily activity").font(.headline)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(d.seconds > 0 ? AnyShapeStyle(Color.accentColor.opacity(0.85))
                                            : AnyShapeStyle(.white.opacity(0.08)))
                        .frame(height: max(3, 92 * d.seconds / peak))
                        .help("\(d.day.formatted(.dateTime.month().day())) — \(hours(d.seconds))")
                }
            }
            .frame(height: 92, alignment: .bottom)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 13))
        }
    }

    private var artists: some View {
        let top = history.topArtists(since: since)
        let peak = max(top.first?.seconds ?? 1, 1)
        return VStack(alignment: .leading, spacing: 9) {
            Text("Top artists").font(.headline)
            VStack(spacing: 7) {
                ForEach(Array(top.enumerated()), id: \.offset) { i, a in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.name).font(.callout).lineLimit(1)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.75))
                                    .frame(width: max(3, geo.size.width * a.seconds / peak))
                            }
                            .frame(height: 4)
                        }
                        Text(hours(a.seconds)).font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 13))
        }
    }

    private var tracks: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Most played").font(.headline)
            VStack(spacing: 7) {
                ForEach(Array(history.topTracks(since: since).enumerated()), id: \.offset) { i, t in
                    Button {
                        model.engine.play(videoId: t.play.videoId)
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                            Artwork(url: t.play.artworkURL, corner: 5)
                                .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.play.title).font(.callout).lineLimit(1)
                                Text(t.play.artist).font(.caption2)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text("\(t.count)×").font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 13))
        }
    }

    private func hours(_ seconds: Double) -> String {
        let text: String
        if seconds >= 3600 { text = String(format: "%.1fh", seconds / 3600) }
        else if seconds >= 60 { text = "\(Int(seconds / 60))m" }
        else { text = "\(Int(seconds))s" }
        // Imported and scrobbled plays carry a stand-in length, so the total is
        // an estimate and says so rather than borrowing the authority of the
        // figures beside it.
        return history.hasEstimates(since: since) ? "≈\(text)" : text
    }
}

/// Where the numbers above come from, and how to add to them.
///
/// This is deliberately on the dashboard rather than buried in a settings
/// window: importing history changes what every figure on this page means, so
/// the provenance belongs next to the figures.
private struct StatsSources: View {
    @Bindable var model: AppModel

    @State private var showingLastfm = false
    @State private var showingImporter = false
    @State private var key = ""
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where these come from")
                .font(.callout.weight(.medium))

            row(icon: "waveform",
                title: PlatformWording.thisDevice.replacingOccurrences(of: "this ", with: "This "),
                detail: "Every play Prism handles, timed exactly.",
                trailing: { Text("always on").font(.caption).foregroundStyle(.secondary) })

            Divider()

            row(icon: "square.and.arrow.down",
                title: "Google Takeout",
                detail: "Your full history from every device, going back years. Play counts and dates are exact; listening time is estimated.",
                trailing: {
                    Button(model.importing ? "Importing…" : "Import…") { pickFile() }
                        .disabled(model.importing)
                })

            Divider()

            row(icon: "dot.radiowaves.left.and.right",
                title: "Last.fm",
                detail: lastfmDetail,
                trailing: {
                    if model.scrobbler.isConnected {
                        Button("Disconnect") { model.scrobbler.disconnect() }
                    } else {
                        Button("Connect…") { showingLastfm = true }
                    }
                })

            if let status = model.importStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 13))
        .sheet(isPresented: $showingLastfm) { lastfmSheet }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            // A file handed over by the document picker is outside the app's
            // sandbox, so it has to be opened under a security scope or the
            // read fails with a permission error that looks like a bad file.
            let scoped = url.startAccessingSecurityScopedResource()
            model.importTakeout(from: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private var lastfmDetail: String {
        switch model.scrobbler.state {
        case .connected(let user):
            let queued = model.scrobbler.queued
            return queued > 0
                ? "Signed in as \(user). \(queued) waiting to send."
                : "Signed in as \(user). Plays are sent as you listen."
        case .awaitingApproval:
            return "Approve Prism in the browser, then press Done."
        default:
            return "Sends your plays to Last.fm so your stats follow you off \(PlatformWording.thisDevice). Needs a free API key."
        }
    }

    private func row<T: View>(icon: String, title: String, detail: String,
                              @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    /// A plain open panel rather than `.fileImporter`, because the file lives
    /// inside an unzipped Takeout folder and the sandbox is not in play here.
    private func pickFile() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose watch-history.json from your Takeout export"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importTakeout(from: url)
        #else
        // iOS has no modal open panel; the sheet below drives the same import.
        showingImporter = true
        #endif
    }

    private var lastfmSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Last.fm").font(.headline)
            Text("Last.fm gives out API keys free. Create one, then paste both values here — they are stored in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)

            Link("Create an API account →",
                 destination: URL(string: "https://www.last.fm/api/account/create")!)
                .font(.caption)

            TextField("API key", text: $key).textFieldStyle(.roundedBorder)
            TextField("Shared secret", text: $secret).textFieldStyle(.roundedBorder)

            if case .awaitingApproval = model.scrobbler.state {
                Text("Approve Prism in the browser that just opened, then press Done.")
                    .font(.caption).foregroundStyle(Color.accentColor)
            }
            if let error = model.scrobbler.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { showingLastfm = false }
                Spacer()
                if case .awaitingApproval = model.scrobbler.state {
                    Button("Done") {
                        Task {
                            await model.scrobbler.finishConnecting()
                            if model.scrobbler.isConnected {
                                showingLastfm = false
                                model.syncScrobbles()
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Authorise") {
                        model.scrobbler.saveCredentials(key: key, secret: secret)
                        Task { await model.scrobbler.beginConnecting() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty || secret.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
