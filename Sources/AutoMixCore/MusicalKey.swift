import Foundation

/// A key in Camelot ("harmonic mixing") notation.
///
/// The wheel is twelve numbers around a clock, each with an A side (minor) and
/// a B side (major). Keys that sit next to each other on it share most of their
/// notes, which is why DJs mix between them.
public struct MusicalKey: Equatable, Hashable, Sendable {

    public enum Mode: String, Sendable { case major, minor }

    /// 0 = C, 1 = C♯/D♭, … 11 = B.
    public let pitchClass: Int
    public let mode: Mode

    public init(pitchClass: Int, mode: Mode) {
        self.pitchClass = ((pitchClass % 12) + 12) % 12
        self.mode = mode
    }

    // Camelot number for each pitch class, indexed 0…11.
    private static let majorNumbers = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    private static let minorNumbers = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]

    public var camelotNumber: Int {
        mode == .major ? Self.majorNumbers[pitchClass] : Self.minorNumbers[pitchClass]
    }

    public var camelotLetter: String { mode == .major ? "B" : "A" }

    /// e.g. "8B" for C major, "8A" for A minor.
    public var camelot: String { "\(camelotNumber)\(camelotLetter)" }

    /// Parses "8A", "12B", case-insensitive.
    public init?(camelot: String) {
        let text = camelot.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = text.last, letter == "A" || letter == "B",
              let number = Int(text.dropLast()), (1...12).contains(number)
        else { return nil }
        let mode: Mode = letter == "B" ? .major : .minor
        let table = mode == .major ? Self.majorNumbers : Self.minorNumbers
        guard let pc = table.firstIndex(of: number) else { return nil }
        self.init(pitchClass: pc, mode: mode)
    }

    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    public var name: String {
        "\(Self.names[pitchClass]) \(mode == .major ? "major" : "minor")"
    }
}

/// How two keys sit relative to each other on the wheel.
public enum HarmonicRelation: String, Sendable {
    /// The same key.
    case identical
    /// Relative major/minor — same number, other side of the wheel.
    case relative
    /// One step around the wheel; shares all but one note.
    case adjacent
    /// Two steps up, the classic "lift" that raises energy.
    case energyBoost
    /// Not harmonically related. Mixing these will sound sour.
    case clash

    /// 0…1, for weighting a transition decision.
    public var score: Double {
        switch self {
        case .identical:   1.0
        case .relative:    0.9
        case .adjacent:    0.85
        case .energyBoost: 0.6
        case .clash:       0.2
        }
    }

    /// Whether a long, overlapping blend is musically safe.
    public var allowsLongBlend: Bool { self != .clash }
}

public enum Harmony {

    /// Classifies the move from `a` to `b` on the Camelot wheel.
    public static func relation(from a: MusicalKey, to b: MusicalKey) -> HarmonicRelation {
        if a == b { return .identical }

        let step = wheelDistance(from: a.camelotNumber, to: b.camelotNumber)

        if a.camelotNumber == b.camelotNumber { return .relative }
        if a.mode == b.mode {
            if abs(step) == 1 { return .adjacent }
            if step == 2 { return .energyBoost }
        }
        return .clash
    }

    /// Signed distance on a 12-hour clock, in −6…6.
    static func wheelDistance(from a: Int, to b: Int) -> Int {
        var d = (b - a) % 12
        if d > 6 { d -= 12 }
        if d < -6 { d += 12 }
        return d
    }
}
