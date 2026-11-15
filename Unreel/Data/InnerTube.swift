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

    func browse(_ browseId: String, params: String? = nil) async throws -> J {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await post("browse", body)
    }

    func continuation(_ endpoint: String, token: String) async throws -> J {
        try await post(endpoint, ["continuation": token])
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
