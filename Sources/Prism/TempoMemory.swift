import Foundation

/// Every song's tempo and beat, as Prism has heard them, kept on this Mac.
///
/// AutoMix needs both tracks' tempos to beat-match a blend, and the online
/// lookup it had (Deezer) answers `bpm: 0` for most tracks — the crossfade log
/// read "no analysis yet; using the set length" on nearly every transition, so
/// most mixes were a plain volume fade. Prism now hears tempo itself (the beat
/// tracker behind the rim), so each song it has listened to carries its own
/// numbers into the next mix: the tempo, and where its beats fall in its own
/// timeline, which is what lets two songs' beats be put on top of each other.
@MainActor
final class TempoMemory {

    struct Heard: Codable {
        /// Seconds per beat.
        var period: Double
        /// A beat falls at `phase + k·period` in the song's own seconds.
        var phase: Double?
        /// Length of the recording the phase was heard on. Another version
        /// of a song (Song vs Video, instrumental vs vocal) shares its tempo
        /// but only shares its beat positions if it is the same length — the
        /// same master — so this is what decides whether `phase` carries over.
        var duration: Double?
        /// Heard on this exact video, rather than on another version of it.
        var direct: Bool?
        /// Where a bar starts, in the song's own seconds, modulo a bar.
        var barPhase: Double?
        /// Where the song gets big — its drop or first hook — on a downbeat,
        /// in its own seconds. Where a switch brings it in.
        var dropAt: Double?
        var heardAt: Date
    }

    private var store: [String: Heard] = [:]
    private let key = "prism.tempoMemory"
    private var saveTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: Heard].self, from: data) {
            store = saved
        }
    }

    func heard(_ videoId: String) -> Heard? { store[videoId] }

    var count: Int { store.count }

    func remember(_ videoId: String, period: Double, phase: Double?, duration: Double,
                  direct: Bool, barPhase: Double? = nil, dropAt: Double? = nil) {
        // What was heard on the video itself beats what was heard on another
        // version of it.
        let known = store[videoId]
        if !direct, known?.direct == true { return }
        // A drop or bar heard once is kept until a better reading replaces it.
        let same = known.map { abs($0.period / period - 1) < 0.03 } ?? false
        store[videoId] = Heard(period: period, phase: phase, duration: duration,
                               direct: direct,
                               barPhase: barPhase ?? (same ? known?.barPhase : nil),
                               dropAt: dropAt ?? (same ? known?.dropAt : nil),
                               heardAt: Date())
        // Oldest out past a few thousand songs; a few hundred KB at most.
        if store.count > 4000,
           let oldest = store.min(by: { $0.value.heardAt < $1.value.heardAt })?.key {
            store.removeValue(forKey: oldest)
        }
        // Coalesced: this is called every second while a lock holds.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self,
                  let data = try? JSONEncoder().encode(self.store) else { return }
            UserDefaults.standard.set(data, forKey: self.key)
        }
    }
}
