import Foundation
import CryptoKit
import Observation

/// Last.fm, so listening follows you off this Mac.
///
/// Prism's own log is complete and exact, but only for what happens *here*.
/// Last.fm is the one place that can hold plays from everywhere at once, which
/// makes it the only way the dashboard can know about a phone.
///
/// **One thing this cannot do on its own.** YouTube Music does not scrobble.
/// Nothing reaches Last.fm from a phone unless a scrobbler app is installed
/// there and pointed at it — Pano Scrobbler handles YouTube Music on Android;
/// on iOS there is no good option for it. Prism scrobbles its own plays the
/// moment this is connected, and picks up anything else the account receives.
///
/// Credentials are the user's own: Last.fm hands out API keys free at
/// <https://www.last.fm/api/account/create>, and an app that is not
/// distributed has no business shipping a shared one.
@MainActor
@Observable
final class Scrobbler {

    enum State: Equatable {
        case notConfigured          // no API key yet
        case disconnected           // key present, nobody signed in
        case awaitingApproval       // browser is open, waiting on the user
        case connected(user: String)
    }

    private(set) var state: State = .notConfigured
    private(set) var lastError: String?
    /// Plays waiting for the network to come back.
    private(set) var queued: Int = 0
    private(set) var scrobbledThisSession = 0

    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    // The key is not a secret; the shared secret and the session key are.
    private var apiKey: String {
        get { UserDefaults.standard.string(forKey: "prism.lastfm.key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "prism.lastfm.key") }
    }
    private var username: String {
        get { UserDefaults.standard.string(forKey: "prism.lastfm.user") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "prism.lastfm.user") }
    }

    private var sharedSecret: String {
        get { Keychain.read("prism.lastfm.secret") ?? "" }
        set { Keychain.write(newValue, for: "prism.lastfm.secret") }
    }
    private var sessionKey: String {
        get { Keychain.read("prism.lastfm.session") ?? "" }
        set { Keychain.write(newValue, for: "prism.lastfm.session") }
    }

    /// Scrobbles that failed to send, kept on disk so a dropped connection or a
    /// quit does not lose them. Last.fm accepts backdated scrobbles, so these
    /// stay correct however late they arrive.
    private var pending: [Play] = []
    private let pendingURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prism", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("scrobble-queue.json")
    }()

    init() {
        loadPending()
        refreshState()
    }

    private func refreshState() {
        if apiKey.isEmpty || sharedSecret.isEmpty { state = .notConfigured }
        else if sessionKey.isEmpty { state = .disconnected }
        else { state = .connected(user: username) }
    }

    var isConnected: Bool { if case .connected = state { return true }; return false }

    // MARK: Setup

    func saveCredentials(key: String, secret: String) {
        apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        sharedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        refreshState()
    }

    func disconnect() {
        sessionKey = ""
        username = ""
        refreshState()
    }

    /// Last.fm's desktop flow: fetch a request token, send the user to approve
    /// it in a browser, then trade the approved token for a session key that
    /// never expires.
    ///
    /// The approval step happens outside the app, so there is nothing to poll
    /// against — `finishConnecting()` is the user telling us they are done.
    func beginConnecting() async {
        lastError = nil
        guard !apiKey.isEmpty, !sharedSecret.isEmpty else {
            lastError = "Enter your API key and shared secret first."
            return
        }
        do {
            let token: String = try await call("auth.getToken", signed: true) { json in
                guard let t = json["token"] as? String else { throw Fault.badResponse }
                return t
            }
            requestToken = token
            state = .awaitingApproval
            if let url = URL(string:
                "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)") {
                PlatformOpener.open(url)
            }
        } catch {
            lastError = readable(error)
            refreshState()
        }
    }

    private var requestToken: String?

    /// Called once the user has approved in the browser.
    func finishConnecting() async {
        guard let token = requestToken else {
            lastError = "Start the connection first."
            return
        }
        do {
            let name: String = try await call("auth.getSession", signed: true,
                                              extra: ["token": token]) { json in
                guard let session = json["session"] as? [String: Any],
                      let key = session["key"] as? String,
                      let name = session["name"] as? String else { throw Fault.badResponse }
                // Assigning inside the parser keeps the two inseparable — a
                // session key without its username is useless for display.
                Task { @MainActor in
                    self.sessionKey = key
                    self.username = name
                }
                return name
            }
            username = name
            requestToken = nil
            refreshState()
            await flushPending()
        } catch {
            // The overwhelmingly common cause is pressing Done before actually
            // approving, so say that rather than echoing the raw fault.
            lastError = "Last.fm has not approved yet — approve in the browser, then try again."
            state = .disconnected
        }
    }

    // MARK: Sending

    /// Tells Last.fm what is playing. Best effort: this is cosmetic on their
    /// profile and never worth surfacing an error for.
    func nowPlaying(_ track: Track) async {
        guard isConnected, !track.artist.isEmpty, !track.title.isEmpty else { return }
        _ = try? await call("track.updateNowPlaying", signed: true, post: true, extra: [
            "artist": track.artist, "track": track.title, "sk": sessionKey
        ]) { _ in true }
    }

    /// Submits a finished play.
    ///
    /// Last.fm's rules, applied here rather than sending everything and letting
    /// them reject it: a track must be longer than 30 seconds, and must have
    /// been played for at least half its length or four minutes, whichever
    /// comes first. Prism only logs a play after 25 seconds anyway, so this
    /// mostly catches half-listened long tracks.
    func scrobble(_ play: Play, trackLength: Double) async {
        guard isConnected, !play.artist.isEmpty, !play.title.isEmpty else { return }
        guard trackLength > 30 else { return }
        guard play.seconds >= min(trackLength / 2, 240) else { return }

        if await send([play]) {
            scrobbledThisSession += 1
        } else {
            pending.append(play)
            savePending()
        }
    }

    /// Retries anything that failed earlier. Sent in batches of 50, which is
    /// Last.fm's limit for a single scrobble call.
    func flushPending() async {
        guard isConnected, !pending.isEmpty else { return }
        while !pending.isEmpty {
            let batch = Array(pending.prefix(50))
            guard await send(batch) else { break }
            pending.removeFirst(batch.count)
            scrobbledThisSession += batch.count
            savePending()
        }
        savePending()
    }

    private func send(_ batch: [Play]) async -> Bool {
        var extra: [String: String] = ["sk": sessionKey]
        for (i, play) in batch.enumerated() {
            extra["artist[\(i)]"] = play.artist
            extra["track[\(i)]"] = play.title
            extra["timestamp[\(i)]"] = String(Int(play.at.timeIntervalSince1970))
        }
        do {
            return try await call("track.scrobble", signed: true, post: true, extra: extra) { _ in true }
        } catch {
            lastError = readable(error)
            return false
        }
    }

    // MARK: Pulling other devices back in

    /// Fetches plays Last.fm knows about that Prism does not — the phone, the
    /// web player, anything else scrobbling to the same account.
    ///
    /// Returns them as `.scrobbled` plays; `History.merge` drops the ones that
    /// are really Prism's own scrobbles coming back around.
    func recentPlays(since: Date, limit pages: Int = 8) async -> [Play] {
        guard isConnected else { return [] }
        var out: [Play] = []

        for page in 1...pages {
            let batch: [Play]
            do {
                batch = try await call("user.getRecentTracks", signed: false, extra: [
                    "user": username, "limit": "200", "page": String(page),
                    "from": String(Int(since.timeIntervalSince1970))
                ]) { json in
                    guard let root = json["recenttracks"] as? [String: Any],
                          let items = root["track"] as? [[String: Any]] else { return [] }
                    return items.compactMap(Self.play(from:))
                }
            } catch {
                lastError = readable(error)
                break
            }
            if batch.isEmpty { break }
            out.append(contentsOf: batch)
        }
        return out
    }

    private static func play(from item: [String: Any]) -> Play? {
        // A track currently playing has no date and is not a finished listen.
        guard let date = item["date"] as? [String: Any],
              let uts = date["uts"] as? String, let seconds = Double(uts) else { return nil }
        let title = (item["name"] as? String) ?? ""
        let artist = ((item["artist"] as? [String: Any])?["#text"] as? String) ?? ""
        guard !title.isEmpty else { return nil }

        // Last.fm has no video IDs, so identity is the track itself. Lowercased
        // and joined so the same song from Prism and from a phone collapses to
        // one entry rather than two near-identical ones.
        let key = "lastfm:\(artist.lowercased())|\(title.lowercased())"
        return Play(videoId: key, title: title, artist: artist, artworkURL: nil,
                    at: Date(timeIntervalSince1970: seconds),
                    seconds: Play.assumedLength, source: .scrobbled)
    }

    // MARK: Transport

    private enum Fault: Error { case badResponse, api(Int, String) }

    private func call<T>(_ method: String, signed: Bool, post: Bool = false,
                         extra: [String: String] = [:],
                         parse: @escaping ([String: Any]) throws -> T) async throws -> T {

        var params = extra
        params["method"] = method
        params["api_key"] = apiKey
        if signed { params["api_sig"] = signature(params) }
        params["format"] = "json"          // never part of the signature

        var request: URLRequest
        if post {
            request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = encode(params).data(using: .utf8)
        } else {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.percentEncodedQuery = encode(params)
            request = URLRequest(url: components.url!)
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Fault.badResponse
        }
        if let code = json["error"] as? Int {
            throw Fault.api(code, (json["message"] as? String) ?? "unknown")
        }
        return try parse(json)
    }

    /// Last.fm signs a call by concatenating every parameter as `name+value` in
    /// order of the *name*, appending the shared secret, and taking the MD5.
    /// `format` is excluded, and so is the signature itself.
    private func signature(_ params: [String: String]) -> String {
        let joined = params
            .filter { $0.key != "format" && $0.key != "api_sig" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined()
        let digest = Insecure.MD5.hash(data: Data((joined + sharedSecret).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func encode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    private func readable(_ error: Error) -> String {
        switch error {
        case Fault.api(let code, let message):
            // 4 and 9 both mean "your credentials are wrong", which is far more
            // actionable than Last.fm's own wording.
            if code == 4 || code == 9 { return "Last.fm rejected the login — reconnect." }
            if code == 10 || code == 26 { return "That API key is not valid." }
            if code == 13 { return "Signature rejected — check the shared secret." }
            return "Last.fm error \(code): \(message)"
        case Fault.badResponse:
            return "Last.fm sent something unreadable."
        default:
            return (error as NSError).localizedDescription
        }
    }

    // MARK: Queue storage

    private func loadPending() {
        guard let data = try? Data(contentsOf: pendingURL),
              let decoded = try? JSONDecoder().decode([Play].self, from: data) else { return }
        pending = decoded
        queued = pending.count
    }

    private func savePending() {
        queued = pending.count
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: pendingURL, options: .atomic)
    }
}

/// Just enough Keychain for two secrets.
///
/// The shared secret and session key are not put in `UserDefaults` because a
/// preferences plist is world-readable within the user account and a session
/// key is a permanent credential for the Last.fm account.
enum Keychain {

    static func write(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.gerald.prism",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.gerald.prism",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
