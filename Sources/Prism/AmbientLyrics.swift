import SwiftUI
// A module on macOS, compiled into the binary on iOS — see build-ios.sh.
#if canImport(AutoMixCore)
import AutoMixCore
#endif

/// Locked-mode lyrics.
///
/// Every style below is a **pure function of the playback clock**: the prism's
/// roll angle, each split-flap tile, each falling word is computed from how
/// long ago its line or word began. There is no animation state to fall out of
/// step, so a seek, a skip or a burst of fast lines can never leave anything
/// stuck half-turned — the next frame is simply drawn from the new time.
struct AmbientLyricsView: View {
    @Bindable var model: AppModel
    var style: AmbientSettings.LyricStyle

    var body: some View {
        Group {
            if model.lyricsLoading && model.lyrics == nil {
                ProgressView().controlSize(.large).tint(.white)
            } else if let lyrics = model.lyrics, !lyrics.isEmpty {
                if lyrics.synced {
                    timed(lyrics.timed, source: lyrics.source)
                } else {
                    UntimedLyrics(model: model, lyrics: lyrics)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble").font(.system(size: 34, weight: .light))
                    Text("No lyrics for this track").font(.system(size: 18))
                }
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func timed(_ lines: [TimedLine], source: String) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let time = model.engine.smoothTime(at: tl.date)
            let frame = LyricFrame(lines: lines,
                                   moment: LyricTiming.moment(in: lines, at: time),
                                   time: time, accent: model.palette.accent,
                                   seek: { model.engine.seek(to: $0) })
            ZStack {
                switch style {
                case .prism:       PrismLyrics(frame: frame)
                case .splitFlap:   SplitFlapLyrics(frame: frame)
                case .depthTunnel: TunnelLyrics(frame: frame)
                case .wordRain:    RainLyrics(frame: frame)
                // The surface resolves Random to a real style before it gets here.
                case .liquidFill, .random: LiquidLyrics(frame: frame)
                }
                if let gap = frame.moment.gap { GapDots(gap: gap, accent: frame.accent) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(source) · word timing estimated")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.28))
                .padding(18)
        }
    }
}

/// Everything a style needs for one frame.
struct LyricFrame {
    let lines: [TimedLine]
    let moment: LyricMoment
    let time: Double
    let accent: Color
    let seek: (Double) -> Void

    var index: Int? { moment.lineIndex }
    func text(_ i: Int) -> String? { lines.indices.contains(i) ? lines[i].text : nil }

    /// Fractional line position, easing from the previous line to the current
    /// one over the first `over` seconds of each line. Before the first line
    /// it rests at -1, so line 0 waits as the upcoming one.
    func position(over: Double = 0.5) -> Double {
        guard let i = index else { return -1 }
        let k = min(max((time - lines[i].start) / over, 0), 1)
        let eased = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
        return Double(i - 1) + eased
    }

    /// Progress of each word of line `i` at this instant.
    func words(of i: Int) -> [(String, Double)] {
        let ws = LyricTiming.words(lines[i].text)
        if i == index { return Array(zip(ws, moment.wordProgress)) }
        let windows = LyricTiming.wordWindows(in: lines, line: i)
        return zip(ws, windows).map { w, win in
            (w, min(max((time - win.start) / win.duration, 0), 1))
        }
    }
}

// MARK: - Shared pieces

/// A word that fills left to right in the accent colour as it is sung, then
/// settles to white. The fill is a gradient mask in the word's own bounds, so
/// no geometry has to be measured per word.
struct KaraokeWord: View {
    let text: String
    let progress: Double
    let accent: Color
    var size: CGFloat = 52

    private var singing: Bool { progress > 0 && progress < 1 }

    var body: some View {
        let font = Font.system(size: size, weight: .bold, design: .rounded)
        Text(text).font(font)
            .foregroundStyle(.white.opacity(0.26))
            .overlay {
                Text(text).font(font)
                    .foregroundStyle(progress >= 1 ? AnyShapeStyle(.white) : AnyShapeStyle(accent))
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .black, location: progress),
                            .init(color: .clear, location: min(progress + 0.0001, 1))
                        ], startPoint: .leading, endPoint: .trailing)
                    }
            }
            .scaleEffect(singing ? 1.06 : 1)
            .shadow(color: accent.opacity(singing ? 0.65 : 0), radius: 14)
    }
}

/// Wraps words onto centred rows.
struct CenteredFlow: Layout {
    var spacing: CGFloat = 14
    var rowSpacing: CGFloat = 4

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([]); x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let rs = rows(subviews, width: width)
        let height = rs.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) }
            + rowSpacing * CGFloat(max(rs.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let w = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(row.count - 1, 0))
            let h = row.map(\.1.height).max() ?? 0
            var x = bounds.midX - w / 2
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += h + rowSpacing
        }
    }
}

/// A line of karaoke words.
struct KaraokeLine: View {
    let words: [(String, Double)]
    let accent: Color
    var size: CGFloat = 52

    var body: some View {
        CenteredFlow {
            ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                KaraokeWord(text: w.0, progress: w.1, accent: accent, size: size)
            }
        }
    }
}

/// The instrumental countdown: three dots that fill as the next line nears.
struct GapDots: View {
    let gap: LyricMoment.Gap
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let breathe = 0.85 + 0.15 * sin(tl.date.timeIntervalSinceReferenceDate * 2.4)
            HStack(spacing: 22) {
                ForEach(0..<3, id: \.self) { k in
                    let fill = min(max(gap.progress * 3 - Double(k), 0), 1)
                    Circle()
                        .fill(.white.opacity(0.18))
                        .overlay { Circle().fill(accent).opacity(fill) }
                        .frame(width: 18, height: 18)
                        .scaleEffect(breathe * (0.85 + 0.3 * fill))
                        .shadow(color: accent.opacity(fill * 0.7), radius: 10)
                }
            }
        }
        .offset(y: 150)
    }
}

// MARK: - Prism (default)

/// Lines on the faces of a turning prism. The current line faces you; the next
/// one waits on the lower face at an angle — that is the preview — and the
/// whole prism rolls up as each new line begins.
struct PrismLyrics: View {
    let frame: LyricFrame

    /// Angle between faces. Less than 90° so the next face is readable at a
    /// tilt instead of edge-on.
    private let step = 55.0
    private let faceHeight: CGFloat = 150
    private var radius: CGFloat { faceHeight / (2 * tan(CGFloat(step) * .pi / 360)) }

    var body: some View {
        let f = frame.position()
        let centre = Int(f.rounded())
        ZStack {
            ForEach(max(centre - 1, 0)...max(centre + 2, 0), id: \.self) { k in
                if let text = frame.text(k) {
                    face(k, text: text, angle: (Double(k) - f) * step)
                }
            }
        }
        .frame(maxWidth: 980)
    }

    @ViewBuilder
    private func face(_ k: Int, text: String, angle: Double) -> some View {
        if abs(angle) < 86 {
            let a = angle * .pi / 180
            let front = cos(a)
            Group {
                if k == frame.index {
                    KaraokeLine(words: frame.words(of: k), accent: frame.accent)
                } else {
                    Text(text)
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(k < (frame.index ?? -1) ? 0.3 : 0.55))
                        .multilineTextAlignment(.center)
                        .onTapGesture { frame.seek(frame.lines[k].start) }
                }
            }
            .frame(height: faceHeight)
            .rotation3DEffect(.degrees(-angle), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
            .offset(y: CGFloat(sin(a)) * radius)
            .opacity(pow(max(front, 0), 1.6))
            .zIndex(front)
        }
    }
}

// MARK: - Split-flap

/// Each new line clatters in character by character, like a departure board.
struct SplitFlapLyrics: View {
    let frame: LyricFrame

    var body: some View {
        VStack(spacing: 34) {
            if let i = frame.index, let text = frame.text(i) {
                board(text, line: i)
            }
            if let next = frame.text((frame.index ?? -1) + 1) {
                Text(next.uppercased())
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
                    .onTapGesture { frame.seek(frame.lines[(frame.index ?? -1) + 1].start) }
            }
        }
        .frame(maxWidth: 1000)
    }

    private func board(_ text: String, line i: Int) -> some View {
        let start = frame.lines[i].start
        let words = frame.words(of: i)
        // Map each character to the word it belongs to, to light it when sung.
        var owner: [Int] = []
        for (w, word) in words.enumerated() {
            owner += Array(repeating: w, count: word.0.count)
            owner.append(w)                            // the space after it
        }
        let chars = Array(text.uppercased())
        return CenteredFlow(spacing: 3, rowSpacing: 8) {
            ForEach(Array(chars.enumerated()), id: \.offset) { j, ch in
                let flip = min(max((frame.time - start - Double(j) * 0.018) / 0.22, 0), 1)
                let sung = j < owner.count && owner[j] < words.count ? words[owner[j]].1 : 0
                Text(String(ch))
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundStyle(sung > 0 ? AnyShapeStyle(sung >= 1 ? .white : frame.accent)
                                              : AnyShapeStyle(.white.opacity(0.55)))
                    .frame(width: 34, height: 52)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(ch == " " ? 0 : 0.07)))
                    .overlay(Rectangle().fill(.black.opacity(0.35)).frame(height: 1))
                    .rotation3DEffect(.degrees((1 - flip) * 90), axis: (x: 1, y: 0, z: 0),
                                      anchor: .top, perspective: 0.5)
                    .opacity(flip)
            }
        }
    }
}

// MARK: - Depth tunnel

/// Upcoming lines wait in the distance and fly forward as they are sung;
/// finished lines rush past the viewer and vanish.
struct TunnelLyrics: View {
    let frame: LyricFrame

    var body: some View {
        let f = frame.position(over: 0.6)
        let centre = Int(f.rounded())
        ZStack {
            ForEach(max(centre - 1, 0)...max(centre + 3, 0), id: \.self) { k in
                if let text = frame.text(k) {
                    layer(k, text: text, depth: Double(k) - f)
                }
            }
        }
        .frame(maxWidth: 1000)
    }

    @ViewBuilder
    private func layer(_ k: Int, text: String, depth d: Double) -> some View {
        let passed = d < 0
        let scale = passed ? 1 + (-d) * 1.6 : 1 / (1 + 0.6 * d)
        let opacity = passed ? max(1 + d * 2.2, 0) : max(1 - 0.24 * d, 0)
        Group {
            if k == frame.index {
                KaraokeLine(words: frame.words(of: k), accent: frame.accent)
            } else {
                Text(text)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .scaleEffect(scale)
        .offset(y: passed ? 0 : -CGFloat(d) * 46 * CGFloat(scale))
        // Blur only the two farthest lines, and only a little: a blur per line
        // on every frame is exactly the cost this file is trying not to pay.
        .blur(radius: d > 1.2 ? min((d - 1.2) * 1.5, 2.5) : 0)
        .opacity(opacity)
        .zIndex(-d)
    }
}

// MARK: - Word rain

/// Each word drops into place at the moment it is sung, with a small bounce.
/// The next line hangs faintly above, waiting to fall.
struct RainLyrics: View {
    let frame: LyricFrame

    var body: some View {
        VStack(spacing: 40) {
            if let next = frame.text((frame.index ?? -1) + 1) {
                Text(next)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.22))
                    .onTapGesture { frame.seek(frame.lines[(frame.index ?? -1) + 1].start) }
            }
            if let i = frame.index {
                let windows = LyricTiming.wordWindows(in: frame.lines, line: i)
                let words = frame.words(of: i)
                CenteredFlow {
                    ForEach(Array(words.enumerated()), id: \.offset) { n, w in
                        let start = n < windows.count ? windows[n].start : frame.lines[i].start
                        let q = min(max((frame.time - start) / 0.38, 0), 1)
                        KaraokeWord(text: w.0, progress: w.1, accent: frame.accent)
                            .offset(y: -90 * CGFloat(1 - Self.bounce(q)))
                            .opacity(q)
                    }
                }
            }
        }
        .frame(maxWidth: 1000)
    }

    /// Overshoots a little and settles — a landing, not a stop.
    static func bounce(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

// MARK: - Liquid fill

/// The line waits as an outline and fills with the song's colour like ink
/// soaking in, behind a soft moving wave front.
struct LiquidLyrics: View {
    let frame: LyricFrame

    var body: some View {
        VStack(spacing: 36) {
            if let i = frame.index, let text = frame.text(i) {
                let progress = sungFraction(i)
                let font = Font.system(size: 58, weight: .heavy, design: .rounded)
                Text(text).font(font)
                    .foregroundStyle(.white.opacity(0.14))
                    .multilineTextAlignment(.center)
                    .overlay {
                        Text(text).font(font)
                            .foregroundStyle(LinearGradient(colors: [frame.accent, .white],
                                                            startPoint: .bottom, endPoint: .top))
                            .multilineTextAlignment(.center)
                            .mask { wave(progress: progress, phase: frame.time) }
                    }
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
            }
            if let next = frame.text((frame.index ?? -1) + 1) {
                Text(next)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                    .onTapGesture { frame.seek(frame.lines[(frame.index ?? -1) + 1].start) }
            }
        }
        .frame(maxWidth: 1000)
    }

    /// Share of the line's characters sung so far, so long words move the front
    /// further than short ones.
    private func sungFraction(_ i: Int) -> Double {
        let words = frame.words(of: i)
        let total = words.reduce(0) { $0 + Double($1.0.count) }
        guard total > 0 else { return 0 }
        return words.reduce(0) { $0 + Double($1.0.count) * $1.1 } / total
    }

    private func wave(progress: Double, phase: Double) -> some View {
        Canvas { ctx, size in
            let x = size.width * progress
            var path = Path()
            path.move(to: .zero)
            let steps = 24
            for s in 0...steps {
                let y = size.height * Double(s) / Double(steps)
                let dx = progress > 0 && progress < 1
                    ? sin(y / 18 + phase * 5) * 7 : 0
                path.addLine(to: CGPoint(x: x + dx, y: y))
            }
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .color(.black))
        }
    }
}

// MARK: - Untimed

/// For lyrics with no timing at all: a readable window that moves through the
/// sheet in step with the track, since there is nothing finer to follow.
struct UntimedLyrics: View {
    @Bindable var model: AppModel
    let lyrics: Lyrics

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { tl in
            let d = model.engine.snapshot.duration
            let t = model.engine.smoothTime(at: tl.date)
            let lines = lyrics.lines.filter { !$0.text.isEmpty }
            let at = d > 0 && !lines.isEmpty ? Int(Double(lines.count) * t / d) : 0
            VStack(spacing: 14) {
                ForEach(max(at - 2, 0)..<min(at + 4, lines.count), id: \.self) { k in
                    Text(lines[k].text)
                        .font(.system(size: k == at ? 40 : 26,
                                      weight: k == at ? .bold : .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(k == at ? 0.95 : 0.35))
                        .multilineTextAlignment(.center)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: at)
            .frame(maxWidth: 900)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(lyrics.source) · not timed")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.28))
                .padding(18)
        }
    }
}
