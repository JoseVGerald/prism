import SwiftUI
import Observation

/// Everything the ambient lighting is governed by, persisted in `UserDefaults`.
///
/// Shaped like `Transitions`: an observable the panel binds to directly, so
/// there is no copy of the state in the view to fall out of sync.
@MainActor
@Observable
final class AmbientSettings {

    /// How the light moves.
    enum Motion: String, CaseIterable, Identifiable {
        /// Slow continuous breathing plus a slow rotation of the gradient.
        case breathing
        /// Pulses on the beat, using the tempo AutoMix already looks up. Falls
        /// back to breathing on a track whose tempo nobody knows.
        case beat
        /// Driven by the system audio level. Not wired up yet — see the note in
        /// the settings panel and §7 of the design notes.
        case liveAudio

        var id: String { rawValue }
        var label: String {
            switch self {
            case .breathing: return "Breathing"
            case .beat:      return "Beat"
            case .liveAudio: return "Live audio"
            }
        }
    }

    /// How lyrics are drawn in locked mode.
    enum LyricStyle: String, CaseIterable, Identifiable {
        case prism, splitFlap, depthTunnel, wordRain, liquidFill
        /// A different one of the others for each song.
        case random
        var id: String { rawValue }
        var label: String {
            switch self {
            case .prism:       return "Prism"
            case .splitFlap:   return "Split-flap"
            case .depthTunnel: return "Depth tunnel"
            case .wordRain:    return "Word rain"
            case .liquidFill:  return "Liquid fill"
            case .random:      return "Random"
            }
        }
        /// The styles that actually draw — everything but `.random`.
        static let drawn: [LyricStyle] = [.prism, .splitFlap, .depthTunnel, .wordRain, .liquidFill]
    }

    private enum Key {
        static let rim = "prism.ambient.rimGlow"
        static let thickness = "prism.ambient.thickness"
        static let glow = "prism.ambient.glow"
        static let motion = "prism.ambient.motion"
        static let equalizers = "prism.ambient.showEqualizers"
        static let idle = "prism.ambient.idleSeconds"
        static let pulse = "prism.ambient.pulse"
        static let lyricStyle = "prism.ambient.lyricStyle"
        static let flow = "prism.ambient.flow"
        static let lyricsDelay = "prism.lyrics.delay"
    }

    /// The rim of light around the window. On by default — it is the feature.
    var rimGlow: Bool { didSet { store(rimGlow, Key.rim) } }
    /// Width of the crisp line, in points. 1…6.
    var thickness: Double { didSet { store(thickness, Key.thickness) } }
    /// How much bleed there is around the line. 0…1.
    var glow: Double { didSet { store(glow, Key.glow) } }
    var motion: Motion { didSet { store(motion.rawValue, Key.motion) } }
    /// The blocks either side of the cover art. Off in the lit pane by default;
    /// compact mode ignores this and always shows them.
    var showEqualizers: Bool { didSet { store(showEqualizers, Key.equalizers) } }
    /// Seconds of no input before the ambient surface takes over. 30…600.
    var idleSeconds: Double { didSet { store(idleSeconds, Key.idle) } }
    /// How far the light swings between its quietest and brightest, 0…1.
    /// 0 holds a steady line; 1 is the full pulse.
    var pulse: Double { didSet { store(pulse, Key.pulse) } }
    var lyricStyle: LyricStyle { didSet { store(lyricStyle.rawValue, Key.lyricStyle) } }
    /// A light that keeps running round the rim at the song's tempo.
    var flow: Bool { didSet { store(flow, Key.flow) } }
    /// Seconds the lyrics are held back (negative brings them forward), for
    /// when a source's timing sits early or late for this Mac's audio path.
    var lyricsDelay: Double { didSet { store(lyricsDelay, Key.lyricsDelay) } }

    /// Whether the full-screen ambient surface is up right now. Not persisted:
    /// a restart should never come back into it.
    var presenting = false

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    init() {
        let d = UserDefaults.standard
        // `object(forKey:)` rather than `bool(forKey:)`, so a default of true
        // survives a first launch where nothing has been written yet.
        rimGlow = d.object(forKey: Key.rim) as? Bool ?? true
        thickness = d.object(forKey: Key.thickness) as? Double ?? 2
        glow = d.object(forKey: Key.glow) as? Double ?? 0.7
        motion = Motion(rawValue: d.string(forKey: Key.motion) ?? "") ?? .breathing
        showEqualizers = d.object(forKey: Key.equalizers) as? Bool ?? false
        idleSeconds = d.object(forKey: Key.idle) as? Double ?? 120
        pulse = d.object(forKey: Key.pulse) as? Double ?? 0.38
        lyricStyle = LyricStyle(rawValue: d.string(forKey: Key.lyricStyle) ?? "") ?? .prism
        flow = d.object(forKey: Key.flow) as? Bool ?? true
        // A tenth of a second late by default: reported running slightly
        // ahead even after the clock and pacing fixes.
        lyricsDelay = d.object(forKey: Key.lyricsDelay) as? Double ?? 0.1
    }
}
