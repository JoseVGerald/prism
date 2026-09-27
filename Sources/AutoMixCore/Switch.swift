import Foundation

/// The timing of a DJ "switch": the new song sneaks in underneath for a few
/// bars, then everything swaps on the one — the old song cuts and the new one
/// hits at full, at its drop rather than its intro.
public enum SwitchTiming {

    /// When the switch lands: the outgoing bar line nearest `target`, but no
    /// sooner than `overlap` seconds from `now`, so the sneak-in has room.
    /// All in wall seconds; `downbeat` is any outgoing downbeat, `bar` the
    /// length of a bar.
    public static func switchTime(now: Double, target: Double, downbeat: Double,
                                  bar: Double, overlap: Double) -> Double {
        guard bar > 0 else { return max(target, now + overlap) }
        var t = downbeat + ((target - downbeat) / bar).rounded() * bar
        while t < now + overlap - 1e-9 { t += bar }
        return t
    }

    /// Where the incoming track should start, in its own seconds, so that
    /// `entry` — a downbeat in its own time — arrives exactly at the switch,
    /// `overlap` wall seconds after it starts playing at `rate`. If that would
    /// mean starting before the beginning, the entry moves a bar later until
    /// it fits. `bar` is the incoming track's bar in its own seconds.
    public static func incomingStart(entry: Double, overlap: Double, rate: Double,
                                     bar: Double) -> Double {
        let lead = overlap * rate
        var e = entry
        if bar > 0 { while e - lead < 0 { e += bar } }
        return max(e - lead, 0)
    }
}

/// Where a song's energy arrives: the drop, the hook, the first big chorus.
public enum DropFinder {

    /// The downbeat after which the music gets most suddenly bigger.
    ///
    /// `energies[i]` is the loudness at beat `i`; downbeats fall on indices
    /// `firstDownbeat + 4k`. Compares the average of the `window` beats after
    /// each downbeat with the `window` before it, and returns the beat index
    /// with the largest rise — or nil if no rise reaches `minRise` (a ratio),
    /// which is a song that simply starts where it means to go on.
    public static func drop(energies: [Double], firstDownbeat: Int,
                            window: Int = 8, minRise: Double = 1.3) -> Int? {
        guard energies.count >= window * 2, firstDownbeat >= 0 else { return nil }
        var best: (index: Int, rise: Double)?
        var i = firstDownbeat
        while i + window <= energies.count {
            if i >= window {
                let before = energies[(i - window)..<i].reduce(0, +) / Double(window)
                let after = energies[i..<(i + window)].reduce(0, +) / Double(window)
                let rise = after / max(before, 1e-6)
                if rise >= minRise, rise > (best?.rise ?? 0) { best = (i, rise) }
            }
            i += 4
        }
        return best?.index
    }
}

/// Which of the four beats in a bar is the one.
public enum BarPhase {
    /// The beat position with the most low-end accent — the kick on the one.
    /// `accents` holds the summed bass onset strength at each of the four
    /// positions. The one and the three both carry kicks in most pop and hip
    /// hop, so this can land a half bar out; it never lands between beats.
    public static func downbeat(accents: [Double]) -> Int {
        guard accents.count == 4 else { return 0 }
        return accents.indices.max(by: { accents[$0] < accents[$1] }) ?? 0
    }
}
