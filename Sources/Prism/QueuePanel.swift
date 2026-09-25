import SwiftUI

struct QueuePanel: View {
    @Bindable var model: AppModel

    /// Row currently being dragged, and how far it has travelled.
    ///
    /// Deliberately a plain drag *gesture* rather than `.onDrag`/`.onDrop`:
    /// the AppKit drag session started (the row dimmed) but no drop delegate
    /// on any other row ever fired, so the marker stuck to the source gap and
    /// nothing committed. A gesture stays inside SwiftUI and also lets the
    /// list part around the row instead of just drawing an insertion line.
    @State private var dragFrom: Int?
    @State private var dragBy: CGFloat = 0
    private var snap: EngineSnapshot { model.engine.snapshot }

    private static let stride: CGFloat = QueueRow.height + 2
    private static let motion = Animation.spring(response: 0.36, dampingFraction: 0.86)

    /// Where the dragged row would land, clamped to the queue.
    private var dragTarget: Int? {
        guard let from = dragFrom else { return nil }
        let steps = Int((dragBy / Self.stride).rounded())
        return min(max(from + steps, 0), rows.count - 1)
    }

    /// A row's identity: the song, and which copy of it this is — not where
    /// it sits. Keyed by position, removing one row renamed every row below
    /// it, so SwiftUI faded them all out and back in instead of sliding them
    /// up; a move or an insert did the same to everything in between.
    private struct Row: Identifiable {
        let entry: QueueEntry
        let id: String
    }

    /// Edits shown the moment they are made, before YouTube confirms them:
    /// rows being removed, and the order after a move. Each clears itself
    /// once the queue agrees, or after two seconds if it never does.
    @State private var removing: Set<String> = []
    @State private var movedOrder: [String]?

    private var rows: [Row] {
        var copies: [String: Int] = [:]
        var out = snap.queue.map { e -> Row in
            let n = copies[e.videoId, default: 0]
            copies[e.videoId] = n + 1
            return Row(entry: e, id: "\(e.videoId)#\(n)")
        }
        out.removeAll { removing.contains($0.id) }
        if let order = movedOrder {
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            if out.allSatisfy({ rank[$0.id] != nil }) {
                out.sort { rank[$0.id]! < rank[$1.id]! }
            }
        }
        return out
    }

    private func remove(_ row: Row) {
        withAnimation(Self.motion) { _ = removing.insert(row.id) }
        model.removeFromQueue(row.entry)
        expire()
    }

    /// Moves the row showing at `slot` to `target`, on screen at once.
    private func move(from slot: Int, to target: Int) {
        let current = rows
        guard current.indices.contains(slot), current.indices.contains(target), slot != target else { return }
        var order = current.map(\.id)
        let id = order.remove(at: slot)
        order.insert(id, at: target)
        withAnimation(Self.motion) { movedOrder = order }
        model.moveInQueue(from: current[slot].entry.index, to: current[target].entry.index)
        expire()
    }

    @State private var expiry: Task<Void, Never>?
    private func expire() {
        expiry?.cancel()
        expiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(Self.motion) { removing = []; movedOrder = nil }
        }
    }

    /// Drops whatever the queue now agrees with.
    private func reconcile() {
        let ids = Set(rowsFromSnapshot.map(\.id))
        removing = removing.filter { ids.contains($0) }
        if let order = movedOrder, rowsFromSnapshot.map(\.id) == order { movedOrder = nil }
    }

    private var rowsFromSnapshot: [Row] {
        var copies: [String: Int] = [:]
        return snap.queue.map { e in
            let n = copies[e.videoId, default: 0]
            copies[e.videoId] = n + 1
            return Row(entry: e, id: "\(e.videoId)#\(n)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Queue").font(.headline)
                Spacer()
                Text("\(snap.queue.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                UndoButton(model: model)
                // Lit while Prism is holding the queue steady against YouTube's
                // own rebuilds of a radio.
                GlassIconButton(system: model.engine.stableQueue ? "lock.fill" : "lock.open",
                                size: 11, diameter: 28, active: model.engine.stableQueue) {
                    model.engine.stableQueue.toggle()
                    model.flash(model.engine.stableQueue
                                ? "Queue locked — YouTube can't reshuffle it"
                                : "Queue unlocked — YouTube may rebuild radios")
                }
                .help(model.engine.stableQueue
                      ? "Queue locked: when YouTube rebuilds a radio on its own, Prism keeps your queue"
                      : "Queue unlocked: YouTube may replace a radio's upcoming songs")
                GlassIconButton(system: "shuffle", size: 12, diameter: 28,
                                active: snap.shuffled ?? false) {
                    model.shuffleQueue()
                }
                .help("Shuffle queue")
                GlassIconButton(system: "trash", size: 12, diameter: 28) {
                    model.clearQueue()
                }
                .help("Clear everything except the track playing")
                .disabled(snap.queue.count < 2)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            .animation(.easeOut(duration: 0.18), value: snap.undoLabel)

            if snap.queue.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Queue is empty").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            // No explicit `.id(entry.index)` here. Pinning a
                            // row's identity to its slot made SwiftUI treat the
                            // slot as unchanged through a reorder, so the list
                            // kept rendering the old order — and the current
                            // track lost its highlight — until the panel was
                            // torn down and rebuilt. ForEach's own element ids
                            // are what the scroll reader targets below.
                            ForEach(Array(rows.enumerated()), id: \.element.id) { slot, row in
                                self.row(row, slot: slot)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .leading))))
                            }
                        }
                        // Shuffling rewrites most of the list at once. Without
                        // this the rows swap instantly and it is impossible to
                        // see that anything happened, let alone that the track
                        // you are on stayed put. Stable row identities are what
                        // let it slide rows rather than cross-fade them.
                        .animation(Self.motion, value: rows.map(\.id))
                        .padding(.horizontal, 8).padding(.bottom, 12)
                    }
                    .scrollDisabled(dragFrom != nil)
                    .onChange(of: snap.queueIndex) { _, new in
                        guard dragFrom == nil,
                              let row = rows.first(where: { $0.entry.index == new }) else { return }
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(row.id, anchor: .center)
                        }
                    }
                    .onChange(of: snap.queue.map(\.videoId)) { _, _ in reconcile() }
                }
            }
        }
        // Fixed width on the Mac, where it is a sidebar; full width on iOS,
        // where it is a sheet and 290pt would leave it floating in a gutter.
        #if canImport(AppKit)
        .frame(width: 290)
        #else
        .frame(maxWidth: .infinity)
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    @ViewBuilder
    private func row(_ row: Row, slot: Int) -> some View {
        let lifted = dragFrom == slot
        let count = rows.count
        QueueRow(model: model, entry: row.entry,
                 isCurrent: row.entry.index == snap.queueIndex,
                 slot: slot, total: count,
                 lifted: lifted,
                 onRemove: { remove(row) },
                 onMove: { target in move(from: slot, to: min(max(target, 0), count - 1)) })
            .offset(y: lifted ? dragBy : shift(for: slot))
            .zIndex(lifted ? 1 : 0)
            .highPriorityGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if dragFrom == nil { dragFrom = slot }
                        dragBy = value.translation.height
                    }
                    .onEnded { _ in commit(from: slot) }
            )
    }

    /// How far a row slides to open the gap the dragged row is heading for.
    private func shift(for index: Int) -> CGFloat {
        guard let from = dragFrom, let to = dragTarget, index != from else { return 0 }
        if from < to, index > from, index <= to { return -Self.stride }
        if from > to, index >= to, index < from { return Self.stride }
        return 0
    }

    private func commit(from: Int) {
        let to = dragTarget
        guard let to, to != from else {
            withAnimation(Self.motion) { dragFrom = nil; dragBy = 0 }
            return
        }
        // Reorder and settle in one motion, so the row glides into its new
        // place instead of snapping back and then jumping when YouTube agrees.
        withAnimation(Self.motion) {
            dragFrom = nil
            dragBy = 0
        }
        move(from: from, to: to)
    }
}

private struct QueueRow: View {
    @Bindable var model: AppModel
    let entry: QueueEntry
    let isCurrent: Bool
    /// Where the row shows, which the menu's moves are counted from.
    let slot: Int
    let total: Int
    var lifted = false
    let onRemove: () -> Void
    let onMove: (Int) -> Void

    /// Fixed so the drag gesture can convert travel into whole rows.
    static let height: CGFloat = 46

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Same reasoning as TrackRow: a row-wide tap gesture would eat the
            // remove button's clicks.
            Button {
                model.engine.jump(to: entry.index)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Artwork(url: entry.artworkURL, corner: 5)
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.black.opacity(0.5))
                            Image(systemName: model.engine.snapshot.playback.isPlaying
                                  ? "speaker.wave.2.fill" : "pause.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(entry.title)
                                .font(.callout.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor)
                                                           : AnyShapeStyle(.primary))
                                .lineLimit(1)
                            if entry.explicit == true { ExplicitBadge() }
                        }
                        Text(entry.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)

            HStack(spacing: 5) {
                    // Queue items are where YouTube actually exposes the
                    // offline-download action, so it belongs here.
                    Button {
                        model.download(videoId: entry.videoId, title: entry.title,
                                       artist: entry.artist, artworkURL: entry.artworkURL)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plainHit)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help("Download for offline")

                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plainHit)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("Remove from queue")
            }
            // Always laid out rather than hover-revealed, matching TrackRow:
            // hover-only controls make their own coordinates un-clickable.
            .opacity(hovering ? 1 : PlatformInteraction.restingActionOpacity)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(lifted ? 0.2 : (hovering ? 0.12 : (isCurrent ? 0.07 : 0))))
        }
        .overlay {
            if lifted {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: lifted ? 10 : 0, y: lifted ? 4 : 0)
        .scaleEffect(lifted ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: lifted)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // Reordering without dragging — and the only way to reach the far end
        // of a long queue without a scroll-and-drag.
        .contextMenu {
            Button("Play") { model.engine.jump(to: entry.index) }
            Divider()
            Button("Move to Top") { onMove(0) }
                .disabled(slot == 0)
            Button("Move Up") { onMove(slot - 1) }
                .disabled(slot == 0)
            Button("Move Down") { onMove(slot + 1) }
                .disabled(slot >= total - 1)
            Button("Move to Bottom") { onMove(total - 1) }
                .disabled(slot >= total - 1)
            Divider()
            Divider()
            Button("Download for Offline") {
                model.download(videoId: entry.videoId, title: entry.title,
                                       artist: entry.artist, artworkURL: entry.artworkURL)
            }
            Button("Remove from Queue", role: .destructive) {
                onRemove()
            }
        }
    }
}
