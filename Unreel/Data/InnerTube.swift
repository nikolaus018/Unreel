import CryptoKit
import Foundation
import WebKit
import os

/// Client for YouTube's internal API, using the same cookies as the player web view, so signing in
/// once (in the web view) makes the native feeds personal too.
actor InnerTube {
    static let shared = InnerTube()

    enum APIError: LocalizedError {
        case http(Int)
        case message(String)
        var errorDescription: String? {
            switch self {
            case .http(let code): "YouTube returned an error (\(code))."
            case .message(let m): m
            }
        }
    }

    static let origin = "https://m.youtube.com"
    static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v.majorVersion)_\(v.minorVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v.majorVersion).0 Mobile/15E148 Safari/604.1"
    }()
    /// "Reject all" answer to the EU cookie consent, so no consent wall appears.
    static let consentCookie = "CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg"

    private let log = Logger(subsystem: "com.nikolaus.Unreel", category: "innertube")
    private var clientVersion = "2.20261113.00.00"
    private var visitorData: String?
    private var bootstrapped = false
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    // MARK: Endpoints

    func browse(_ browseId: String, params: String? = nil, client: Client = .mweb) async throws -> J {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await post("browse", body, client: client)
    }

    func continuation(_ endpoint: String, token: String, client: Client = .mweb) async throws -> J {
        try await post(endpoint, ["continuation": token], client: client)
    }

    func search(_ query: String, params: String? = nil) async throws -> J {
        var body: [String: Any] = ["query": query]
        if let params { body["params"] = params }
        return try await post("search", body)
    }

    func next(_ videoId: String) async throws -> J {
        try await post("next", ["videoId": videoId])
    }

    // MARK: Signed-in actions

    enum Rating: String { case like, dislike, removelike }

    func rate(_ videoId: String, _ rating: Rating) async throws {
        _ = try await post("like/\(rating.rawValue)", ["target": ["videoId": videoId]])
    }

    func setSubscribed(_ channelId: String, _ subscribed: Bool) async throws {
        _ = try await post(subscribed ? "subscription/subscribe" : "subscription/unsubscribe", ["channelIds": [channelId]])
    }

    func setWatchLater(_ videoId: String, _ saved: Bool) async throws {
        let action: [String: Any] = saved
            ? ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]
            : ["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": videoId]
        _ = try await post("browse/edit_playlist", ["playlistId": "WL", "actions": [action]])
    }

    // MARK: Playlists

    struct PlaylistChoice: Identifiable, Hashable {
        let id: String
        var title: String
        var contains: Bool
        var privacy: String?
    }

    /// The signed-in user's playlists, marked with whether they already hold the video.
    func playlistsForAdding(_ videoId: String) async throws -> [PlaylistChoice] {
        func parse(_ json: J) -> [PlaylistChoice] {
            var out: [PlaylistChoice] = []
            for r in json.all("playlistAddToOptionRenderer") {
                guard let id = r["playlistId"].string else { continue }
                out.append(PlaylistChoice(id: id, title: r["title"].text ?? id,
                                          contains: r["containsSelectedVideos"].string == "ALL",
                                          privacy: r["privacy"].string))
            }
            return out
        }
        let body: [String: Any] = ["videoIds": [videoId], "excludeWatchLater": true]
        let mweb = parse(try await post("playlist/get_add_to_playlist", body))
        if !mweb.isEmpty { return mweb }
        return parse(try await post("playlist/get_add_to_playlist", body, client: .web))
    }

    func setInPlaylist(_ playlistId: String, videoId: String, _ added: Bool) async throws {
        let action: [String: Any] = added
            ? ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]
            : ["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": videoId]
        let json = try await post("browse/edit_playlist", ["playlistId": playlistId, "actions": [action]])
        if let status = json["status"].string, status != "STATUS_SUCCEEDED" { throw APIError.message("YouTube didn't accept the change.") }
    }

    enum Privacy: String, CaseIterable, Identifiable {
        case PRIVATE, UNLISTED, PUBLIC
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// Creates a playlist, optionally with a first video. Returns its ID.
    @discardableResult
    func createPlaylist(title: String, privacy: Privacy, videoId: String?) async throws -> String? {
        var body: [String: Any] = ["title": title, "privacyStatus": privacy.rawValue]
        if let videoId { body["videoIds"] = [videoId] }
        let json = try await post("playlist/create", body)
        return json["playlistId"].string ?? json.first("playlistId").string
    }

    func renamePlaylist(_ playlistId: String, title: String) async throws {
        _ = try await post("browse/edit_playlist", ["playlistId": playlistId,
                                                    "actions": [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]]])
    }

    func deletePlaylist(_ playlistId: String) async throws {
        _ = try await post("playlist/delete", ["playlistId": playlistId])
    }

    // MARK: Comments

    func performCommentAction(_ token: String) async throws {
        _ = try await post("comment/perform_comment_action", ["actions": [token]])
    }

    /// Posts a comment; returns the new comment when YouTube sends it back.
    func createComment(_ text: String, params: String) async throws -> J {
        try await post("comment/create_comment", ["commentText": text, "createCommentParams": params])
    }

    func createReply(_ text: String, params: String) async throws -> J {
        try await post("comment/create_comment_reply", ["commentText": text, "createReplyParams": params])
    }

    /// `createCommentParams` for a video, as YouTube's clients build it (protobuf: field 2 = video ID,
    /// field 5 = {1: 0}, field 10 = 1), for when the comments page doesn't include one.
    static func commentParams(videoId: String) -> String {
        var bytes: [UInt8] = [0x12, UInt8(videoId.utf8.count)] + Array(videoId.utf8)
        bytes += [0x2A, 0x02, 0x08, 0x00, 0x50, 0x01]
        return Data(bytes).base64EncodedString()
    }

    func accountMenu() async throws -> J {
        do {
            return try await post("account/account_menu", [:])
        } catch {
            return try await post("account/account_menu", [:], client: .web)
        }
    }

    /// Search suggestions from YouTube's public autocomplete service.
    func suggestions(_ query: String) async -> [String] {
        var comps = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        comps.queryItems = [.init(name: "client", value: "firefox"), .init(name: "ds", value: "yt"), .init(name: "q", value: query)]
        guard let url = comps.url, let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count > 1,
              let list = json[1] as? [String] else { return [] }
        return Array(list.prefix(8))
    }

    // MARK: Transport

    enum Client { case mweb, web }

    func post(_ endpoint: String, _ body: [String: Any], client kind: Client = .mweb) async throws -> J {
        if !bootstrapped { await bootstrap() }
        let cookies = await Self.youtubeCookies()
        let (clientName, clientNumber, version, platform) = kind == .web
            ? ("WEB", "1", "2.20261112.10.00", "DESKTOP")
            : ("MWEB", "2", clientVersion, "MOBILE")

        var payload = body
        var client: [String: Any] = [
            "clientName": clientName, "clientVersion": version, "platform": platform,
            "hl": Locale.current.language.languageCode?.identifier ?? "en",
            "gl": Locale.current.region?.identifier ?? "US",
            "userAgent": Self.userAgent, "originalUrl": Self.origin + "/",
        ]
        if let visitorData { client["visitorData"] = visitorData }
        payload["context"] = ["client": client, "user": ["lockedSafetyMode": false]]

        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientNumber, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue(Self.origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        request.setValue(Self.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        if let auth = Self.authorization(cookies) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            log.error("\(endpoint, privacy: .public) failed: \(status)")
            if let msg = try? J(data: data)["error"]["message"].string { throw APIError.message(msg) }
            throw APIError.http(status)
        }
        #if DEBUG
        Self.dump(endpoint: endpoint, body: body, data: data)
        #endif
        return try J(data: data)
    }

    #if DEBUG
    /// Debug builds keep the last response per endpoint in Caches/innertube for inspection.
    private static func dump(endpoint: String, body: [String: Any], data: Data) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("innertube")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = endpoint.replacingOccurrences(of: "/", with: "_")
        if let id = body["browseId"] as? String { name += "-" + id }
        if body["continuation"] != nil { name += "-cont" }
        try? data.write(to: dir.appendingPathComponent(name + ".json"))
    }
    #endif

    /// Reads the current client version and visitor ID from the mobile site, so requests look
    /// like they come from an up-to-date browser.
    private func bootstrap() async {
        bootstrapped = true
        var request = URLRequest(url: URL(string: Self.origin + "/")!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.cookieHeader(await Self.youtubeCookies()), forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await session.data(for: request), let html = String(data: data, encoding: .utf8) else { return }
        if let v = html.firstMatch(of: /"INNERTUBE_CLIENT_VERSION":"([^"]+)"/) { clientVersion = String(v.1) }
        if let v = html.firstMatch(of: /"VISITOR_DATA":"([^"]+)"/) { visitorData = String(v.1) }
        log.notice("Bootstrapped client \(self.clientVersion, privacy: .public)")
    }

    /// Call after signing in or out: cookies and visitor ID change.
    func reset() {
        bootstrapped = false
        visitorData = nil
    }

    // MARK: Cookies and auth

    @MainActor
    static func youtubeCookies() async -> [HTTPCookie] {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter { $0.domain.hasSuffix("youtube.com") }
    }

    static func cookieHeader(_ cookies: [HTTPCookie]) -> String {
        var pairs = cookies.map { "\($0.name)=\($0.value)" }
        if !cookies.contains(where: { $0.name == "SOCS" }) { pairs.append("SOCS=\(consentCookie)") }
        return pairs.joined(separator: "; ")
    }

    static func isSignedIn(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
    }

    /// The `SAPISIDHASH` scheme YouTube's web clients use for signed-in requests.
    static func authorization(_ cookies: [HTTPCookie]) -> String? {
        func value(_ name: String) -> String? { cookies.first { $0.name == name }?.value }
        let ts = Int(Date().timeIntervalSince1970)
        func hash(_ secret: String) -> String {
            let digest = Insecure.SHA1.hash(data: Data("\(ts) \(secret) \(origin)".utf8))
            return "\(ts)_" + digest.map { String(format: "%02x", $0) }.joined()
        }
        var parts: [String] = []
        if let s = value("SAPISID") ?? value("__Secure-3PAPISID") { parts.append("SAPISIDHASH " + hash(s)) }
        if let s = value("__Secure-1PAPISID") { parts.append("SAPISID1PHASH " + hash(s)) }
        if let s = value("__Secure-3PAPISID") { parts.append("SAPISID3PHASH " + hash(s)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Makes sure the shared cookie store has the consent cookie before anything loads.
    @MainActor
    static func installConsentCookie() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let existing = await store.allCookies()
        guard !existing.contains(where: { $0.name == "SOCS" && $0.domain.hasSuffix("youtube.com") }) else { return }
        if let cookie = HTTPCookie(properties: [
            .name: "SOCS", .value: consentCookie, .domain: ".youtube.com", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(400 * 86_400),
        ]) {
            await store.setCookie(cookie)
        }
    }
}
