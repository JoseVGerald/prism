import Foundation
// A module on macOS, compiled straight into the binary on iOS — see
// build-ios.sh. `canImport` covers both without forking the file.
#if canImport(AutoMixCore)
import AutoMixCore
#endif

/// Where a track's musical facts come from.
///
/// Prism cannot work any of this out for itself. The audio is decoded inside
/// WebKit from a cross-origin stream, so there is no PCM to analyse — the same
/// wall the loudness meter hit. Anything AutoMix knows has to arrive as
/// metadata from somewhere else.
protocol TrackAnalysisSource: Sendable {
    func analysis(title: String, artist: String, duration: TimeInterval) async -> TrackAnalysis?
}

/// Tempo and loudness from Deezer's public catalogue.
///
/// Chosen because it needs no account, no API key and no signup — it is the
/// only free source found that still answers. AcousticBrainz, which used to
/// carry full audio features, now returns `{"mbid_mapping":{}}` for everything.
///
/// Coverage is partial and honest about it: measured 5 of 7 on real tracks.
/// Deezer publishes no key, so harmonic mixing stays unavailable until a source
/// that has it is plugged in — the planner simply skips that part.
struct DeezerAnalysisSource: TrackAnalysisSource {

    private struct SearchResponse: Decodable {
        struct Item: Decodable { let id: Int; let duration: Int }
        let data: [Item]
    }

    private struct TrackResponse: Decodable {
        let bpm: Double?
        /// Roughly a ReplayGain figure in dB, always negative. The nearest thing
        /// to an energy signal available without the audio.
        let gain: Double?
        let duration: Int?
    }

    func analysis(title: String, artist: String, duration: TimeInterval) async -> TrackAnalysis? {
        guard let match = await search(title: title, artist: artist, duration: duration),
              let track = await fetch(id: match)
        else { return nil }

        // bpm comes back as 0 when Deezer has not measured the track. That is
        // "unknown", not "zero tempo", and must not be passed on as a number.
        let bpm = (track.bpm ?? 0) > 0 ? track.bpm : nil

        // Map gain onto 0…1. Typical values run about −16 dB (quiet, sparse) to
        // −5 dB (loud, dense), so that range is the scale.
        let energy = track.gain.map { min(max(($0 + 16) / 11, 0), 1) }

        return TrackAnalysis(
            id: "\(match)",
            duration: duration,
            bpm: bpm,
            key: nil,                    // Deezer publishes none
            energy: energy,
            introEnd: nil,               // needs the waveform
            outroStart: nil,
            // Only claim confidence when there is actually a tempo to be
            // confident about, or the planner would trust an empty record.
            confidence: bpm == nil ? 0 : 0.8)
    }

    private func search(title: String, artist: String, duration: TimeInterval) async -> Int? {
        let cleanTitle = Self.clean(title)
        let cleanArtist = Self.clean(artist)
        guard !cleanTitle.isEmpty else { return nil }

        var components = URLComponents(string: "https://api.deezer.com/search")!
        components.queryItems = [
            .init(name: "q", value: "artist:\"\(cleanArtist)\" track:\"\(cleanTitle)\""),
            .init(name: "limit", value: "5")
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data)
        else { return nil }

        // Prefer a result whose length matches, which is the cheapest guard
        // against picking a remix, a live cut or a sped-up edit.
        if duration > 0 {
            let best = decoded.data.min {
                abs(Double($0.duration) - duration) < abs(Double($1.duration) - duration)
            }
            if let best, abs(Double(best.duration) - duration) <= 5 { return best.id }
            return nil
        }
        return decoded.data.first?.id
    }

    private func fetch(id: Int) async -> TrackResponse? {
        guard let url = URL(string: "https://api.deezer.com/track/\(id)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(TrackResponse.self, from: data)
    }

    /// Strips the decoration YouTube titles carry, which otherwise sinks the
    /// search — "(Official Video)", "feat. …", and similar.
    private static func clean(_ text: String) -> String {
        var out = text
        for pattern in [#"\s*[\(\[][^)\]]*(official|video|audio|lyrics?|visualizer|remaster|explicit)[^)\]]*[\)\]]"#,
                        #"\s*[\(\[]\s*(feat|ft)\.?[^)\]]*[\)\]]"#,
                        #"\s*-\s*(official|topic).*$"#] {
            out = out.replacingOccurrences(of: pattern, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out.replacingOccurrences(of: "\"", with: "")
                  .trimmingCharacters(in: .whitespaces)
    }
}

/// Caches analyses for the session so a repeated track costs no requests.
@MainActor
final class TrackAnalysisService {

    private let source: TrackAnalysisSource
    private var cache: [String: TrackAnalysis?] = [:]
    private var inFlight: Set<String> = []

    init(source: TrackAnalysisSource = DeezerAnalysisSource()) {
        self.source = source
    }

    /// Already-known analysis, if any. Never blocks — the planner runs on a
    /// deadline and cannot wait for the network mid-transition.
    func cached(_ videoId: String) -> TrackAnalysis? {
        cache[videoId] ?? nil
    }

    /// Fetches in the background so it is ready by the time it is needed.
    func prefetch(videoId: String, title: String, artist: String, duration: TimeInterval) {
        guard cache[videoId] == nil, !inFlight.contains(videoId), !title.isEmpty else { return }
        inFlight.insert(videoId)
        Task {
            let found = await source.analysis(title: title, artist: artist, duration: duration)
            cache[videoId] = found
            inFlight.remove(videoId)
        }
    }
}
