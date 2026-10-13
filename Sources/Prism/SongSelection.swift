import SwiftUI
import Observation
#if canImport(AutoMixCore)
import AutoMixCore
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Picking several songs at once, in any list of songs in the app.
///
/// Shift-click one song and then another to pick everything between them;
/// ⌘-click adds or takes away one. A plain click plays, as it always did, and
/// lets the picks go. The picks belong to one list at a time — a range across
/// two lists means nothing — so picking in a new list starts over.
///
/// Every list takes part the same way: its row asks `click(_:in:scope:)`
/// before playing, marks itself with `selectedSong(_:)`, and shows
/// `SelectionMenu` when right-clicked while picked. The bar at the bottom of
/// the window and the playlist-naming prompt live once, in the root view.
@MainActor
@Observable
final class SongSelection {

    /// The picking itself — pure, and tested in AutoMixCore.
    private var picks = Picks()
    /// Every song seen in a list that was picked from, to turn ids back into
    /// songs.
    @ObservationIgnored private var known: [String: Track] = [:]
    /// Lists shown newest first (Recently played) are reversed for a
    /// playlist, so it plays in the order the songs were heard.
    private(set) var newestFirst = false

    /// The playlist-naming prompt, and the songs it is for when they are
    /// not the picks (a single song's "New Playlist…").
    var naming = false
    var name = ""
    @ObservationIgnored var namingFor: [Track]?

    var scope: String? { picks.scope }
    var isEmpty: Bool { picks.isEmpty }
    var count: Int { picks.ids.count }
    /// Picked songs, in the list's order.
    var tracks: [Track] { picks.ids.compactMap { known[$0] } }
    /// The picks in the order a playlist or the queue should take them.
    var ordered: [Track] { newestFirst ? tracks.reversed() : tracks }

    func contains(_ videoId: String, in scope: String) -> Bool {
        picks.contains(videoId, in: scope)
    }

    /// Handles a click on song `index` of `list`. True when it was a picking
    /// click — shift or ⌘ held — so the row must not also play.
    func click(_ index: Int, in list: [Track], scope: String, newestFirst: Bool = false) -> Bool {
        #if canImport(AppKit)
        let mods = NSEvent.modifierFlags
        let shift = mods.contains(.shift), command = mods.contains(.command)
        #else
        let shift = false, command = false
        #endif
        if shift || command {
            for t in list { known[t.videoId] = t }
            self.newestFirst = newestFirst
        }
        return picks.click(index, in: list.map(\.videoId), scope: scope, shift: shift, command: command)
    }

    func clear() {
        guard !picks.isEmpty || picks.scope != nil else { return }
        picks.clear()
        newestFirst = false
    }

    func askForName(for songs: [Track]? = nil) {
        namingFor = songs
        name = songs?.count == 1 ? songs![0].title
            : (scope == "recent" ? "Picked · " : "Mix · ") + Date().formatted(.dateTime.month(.abbreviated).day())
        naming = true
    }

    /// The songs a new playlist from the prompt should hold.
    var namingSongs: [Track] { namingFor ?? ordered }

    #if canImport(AppKit)
    @ObservationIgnored private var escape: Any?

    init() {
        // Esc lets the picks go, wherever the focus is.
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard !self.isEmpty, !self.naming else { return false }
                self.clear()
                return true
            }
            return handled ? nil : event
        }
    }
    #endif
}

// MARK: - Shared pieces

/// What to do with the picks. Shown in the right-click menu of a picked song.
struct SelectionMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        let n = model.selection.count
        Button("Make a Playlist from \(n) Songs…") { model.selection.askForName() }
        AddToPlaylistMenu(model: model) { model.selection.ordered }
        Button("Play \(n) Songs") {
            model.playTogether(model.selection.ordered)
            model.selection.clear()
        }
        Button("Play \(n) Songs Next") {
            for t in model.selection.ordered.reversed() { model.enqueue(t, atEnd: false) }
            model.selection.clear()
        }
        Button("Add \(n) Songs to Queue") {
            for t in model.selection.ordered { model.enqueue(t, atEnd: true) }
            model.selection.clear()
        }
        if model.selection.scope == "queue" {
            Button("Remove \(n) Songs from Queue", role: .destructive) {
                model.removeFromQueue(videoIds: Set(model.selection.tracks.map(\.videoId)))
                model.selection.clear()
            }
        }
        Divider()
        Button("Clear Selection") { model.selection.clear() }
    }
}

extension View {
    /// Marks a picked song: a tint and an accent outline.
    func selectedSong(_ picked: Bool, corner: CGFloat = 10) -> some View {
        overlay {
            if picked {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: picked)
    }
}

/// The floating bar that says what is picked and what can be done with it.
struct SelectionBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("\(model.selection.count) selected")
                .font(.callout.weight(.semibold))
                .contentTransition(.numericText())
            Divider().frame(height: 16)
            action("Make playlist", "text.badge.plus") { model.selection.askForName() }
            Menu {
                AddToPlaylistMenu(model: model, inline: true) { model.selection.ordered }
            } label: {
                Label("Add to playlist", systemImage: "music.note.list").font(.callout.weight(.medium))
            }
            .menuStyle(.button)
            .buttonStyle(.plainHit)
            .menuIndicator(.hidden)
            .fixedSize()
            action("Play", "play.fill") {
                model.playTogether(model.selection.ordered)
                model.selection.clear()
            }
            action("Add to queue", "text.append") {
                for t in model.selection.ordered { model.enqueue(t, atEnd: true) }
                model.selection.clear()
            }
            Button {
                model.selection.clear()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plainHit)
            .help("Clear selection (Esc)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon).font(.callout.weight(.medium))
        }
        .buttonStyle(.plainHit)
    }
}

/// The bar and the naming prompt, attached once at the root.
struct SelectionHost: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        @Bindable var selection = model.selection
        return content
            .overlay(alignment: .bottom) {
                if !model.selection.isEmpty {
                    SelectionBar(model: model)
                        .padding(.bottom, 64)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.selection.isEmpty)
            .alert("Name the playlist", isPresented: $selection.naming) {
                TextField("Name", text: $selection.name)
                Button("Create") {
                    model.makePlaylist(from: model.selection.namingSongs, named: model.selection.name)
                    if model.selection.namingFor == nil { model.selection.clear() }
                    model.selection.namingFor = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let n = model.selection.namingSongs.count
                Text("\(n == 1 ? "1 song" : "\(n) songs"), saved privately to your YouTube Music library.")
            }
            .onChange(of: model.route) { _, _ in model.selection.clear() }
    }
}

/// "Add to Playlist": your playlists, newest first as YouTube lists them,
/// and a new one. `tracks` is read when a playlist is chosen, so the menu
/// always adds what is picked at that moment.
struct AddToPlaylistMenu: View {
    @Bindable var model: AppModel
    /// Items straight in the enclosing menu rather than in a submenu.
    var inline = false
    let tracks: () -> [Track]

    var body: some View {
        if inline { items } else { Menu("Add to Playlist") { items } }
    }

    @ViewBuilder
    private var items: some View {
        Button("New Playlist…") { model.selection.askForName(for: tracks()) }
        if !model.myPlaylists.isEmpty {
            Divider()
            ForEach(model.myPlaylists) { p in
                Button(p.title) { model.add(tracks(), to: p) }
            }
        } else if !model.engine.isSignedIn {
            Text("Sign in to see your playlists")
        }
    }
}
