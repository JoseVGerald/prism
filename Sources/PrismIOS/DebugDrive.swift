import SwiftUI
import UIKit

/// Drives the interface from outside the app, for verification.
///
/// The iOS Simulator has no tap primitive in `simctl`, and the panel that does
/// have one needs a permission this project cannot assume. Without something
/// like this, every screen past the launch tab is unverifiable — which is worse
/// than a missing feature, because it means a layout that breaks on the phone
/// ships silently.
///
/// So the same trick as `PRISM_EVAL`: watch a file, act on what lands there.
/// Write `search`, `library`, `dashboard`, `forYou`, `player`, `queue`, or
/// `lyrics` into `.prism-eval/ui` inside the app container and the app goes
/// there, exactly as a tap would.
///
/// Gated on `PRISM_EVAL=1` like every other debug affordance here, so it does
/// not exist in a normal run.
@MainActor
final class DebugDrive {

    private let model: AppModel
    private let onPresent: (String) -> Void
    private var task: Task<Void, Never>?

    init(model: AppModel, onPresent: @escaping (String) -> Void) {
        self.model = model
        self.onPresent = onPresent
    }

    func startIfEnabled() {
        guard ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1" else { return }
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".prism-eval")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ui")

        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self,
                      let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
                try? FileManager.default.removeItem(at: file)
                apply(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func rotate(to mask: UIInterfaceOrientationMask) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    private func apply(_ command: String) {
        switch command {
        case "forYou":     model.route = .forYou
        case "nowPlaying": model.route = .nowPlaying
        case "search":    model.route = .search
        case "library":   model.route = .library
        case "dashboard": model.route = .dashboard
        case "lyrics":    model.lyricsMode.toggle()
        case "player", "queue": onPresent(command)
        // Reaches the sign-in webview, which is otherwise only behind a button
        // in the Library empty state.
        case "signin":    model.engine.beginSignIn()
        case "signout":   model.engine.endSignIn()
        case "video":     model.toggleVideoMode()
        // Rotation. `simctl` cannot turn the device and the panel's tap
        // primitive cannot reach the Simulator's own menus, so without this
        // the landscape layout — the one video mode is actually designed for —
        // could not be looked at at all.
        case "landscape": rotate(to: .landscapeRight)
        case "portrait":  rotate(to: .portrait)
        default:
            // `search:<text>` runs a real query, so the results list — the most
            // layout-dense screen in the app — can be looked at with content in
            // it rather than empty.
            // `open:<browseId>` reaches the detail pane, which is otherwise
            // only accessible by tapping a search result.
            // `crossfade:8` sets the transition length; `automix:on|off`
            // toggles the planner. Both are otherwise only reachable through a
            // slider inside a sheet inside the player.
            if command.hasPrefix("crossfade:") {
                let v = Double(command.dropFirst("crossfade:".count)) ?? 0
                model.transitions.seconds = v
                return
            }
            if command.hasPrefix("automix:") {
                model.transitions.autoMix = command.hasSuffix("on")
                return
            }
            if command.hasPrefix("open:") {
                let id = String(command.dropFirst("open:".count))
                model.open(Shelf(browseId: id, title: "Opening…", subtitle: nil,
                                 artworkURL: nil, kind: id.hasPrefix("UC") ? "artist" : "album"))
                return
            }
            if command.hasPrefix("search:") {
                model.route = .search
                model.searchText = String(command.dropFirst("search:".count))
                model.runSearch(immediately: true)
            }
        }
    }
}
