import Foundation

/// Turns band powers into equalizer bar heights, 0…1.
///
/// Each band is read against its own running average, over a 17 dB window:
/// an ordinary moment sits about a quarter up and a hit jumps to the top.
/// Against each band's *peak* instead, most music sat within a few dB of it
/// and the bars read almost full all the time. Per band rather than one
/// scale, because music is far louder in the bass than the treble and on one
/// scale the top half would never move. Power is lightly smoothed first — one
/// FFT frame flickers by several dB from the next, and a meter that rises at
/// once and falls slowly rides those flickers to the top. Bands down in the
/// noise, 55 dB under the loudest, are held at zero.
public struct SpectrumMeter: Sendable {
    public let bands: Int
    private var power: [Double]
    private var averageDB: [Double]
    private var level: [Double]
    private var loudestDB = -60.0
    private var primed = false

    public init(bands: Int) {
        self.bands = bands
        power = Array(repeating: 0, count: bands)
        averageDB = Array(repeating: -60, count: bands)
        level = Array(repeating: 0, count: bands)
    }

    /// One analysis frame (about 94 a second). Returns the bar heights.
    public mutating func update(_ bandPower: [Double]) -> [Double] {
        guard bandPower.count == bands else { return level }
        var db = [Double](repeating: 0, count: bands)
        var loudest = -200.0
        for i in 0..<bands {
            power[i] += (bandPower[i] - power[i]) * 0.35
            db[i] = 10 * log10(power[i] + 1e-12)
            loudest = max(loudest, db[i])
        }
        // Start the averages where the music is, not at an arbitrary floor,
        // so the first seconds do not read as one long hit.
        if !primed, loudest > -90 { averageDB = db; primed = true }
        loudestDB = max(loudestDB - 0.01, loudest)
        for i in 0..<bands {
            averageDB[i] += (db[i] - averageDB[i]) * 0.006          // about 2s
            var v = min(max((db[i] - averageDB[i] + 4.5) / 17, 0), 1)
            if db[i] < loudestDB - 55 || loudest < -90 { v = 0 }
            level[i] += (v - level[i]) * (v > level[i] ? 0.5 : 0.08)
        }
        return level
    }
}
