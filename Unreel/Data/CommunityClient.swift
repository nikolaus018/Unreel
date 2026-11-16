import CryptoKit
import Foundation

/// Dislike counts from Return YouTube Dislike (returnyoutubedislikeapi.com).
actor DislikeClient {
    static let shared = DislikeClient()

    struct Votes: Decodable {
        let likes: Int
        let dislikes: Int
    }

    private var cache: [String: Votes] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    func votes(for videoId: String) async -> Votes? {
        if let hit = cache[videoId] { return hit }
        var comps = URLComponents(string: "https://returnyoutubedislikeapi.com/votes")!
        comps.queryItems = [URLQueryItem(name: "videoId", value: videoId)]
        guard let url = comps.url, let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let votes = try? JSONDecoder().decode(Votes.self, from: data) else { return nil }
        cache[videoId] = votes
        return votes
    }
}

/// Crowd-sourced titles and thumbnails from DeArrow (sponsor.ajay.app). Uses the hash-prefix
/// endpoint like SponsorBlock, so the server never learns which video was looked up.
actor DeArrowClient {
    static let shared = DeArrowClient()

    struct Branding: Equatable {
        var title: String?
        /// Seconds into the video for a community thumbnail; nil keeps the original.
        var thumbnailTime: Double?
    }

    private struct APIBranding: Decodable {
        struct Title: Decodable { let title: String; let original: Bool; let votes: Int; let locked: Bool }
        struct Thumb: Decodable { let timestamp: Double?; let original: Bool; let votes: Int; let locked: Bool }
        let titles: [Title]
        let thumbnails: [Thumb]
    }

    private var cache: [String: Branding] = [:]
    private var inFlight: [String: Task<Branding, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    func branding(for videoId: String) async -> Branding {
        if let hit = cache[videoId] { return hit }
        if let running = inFlight[videoId] { return await running.value }
        let task = Task { await fetch(videoId) }
        inFlight[videoId] = task
        let result = await task.value
        inFlight[videoId] = nil
        cache[videoId] = result
        return result
    }

    private func fetch(_ videoId: String) async -> Branding {
        let prefix = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)
        guard let url = URL(string: "https://sponsor.ajay.app/api/branding/\(prefix)"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let all = try? JSONDecoder().decode([String: APIBranding].self, from: data),
              let b = all[videoId] else { return Branding() }
        return Self.pick(titles: b.titles.map { ($0.title, $0.original, $0.votes, $0.locked) },
                         thumbnails: b.thumbnails.map { ($0.timestamp, $0.original, $0.votes, $0.locked) })
    }

    /// The API sorts by score; use the best entry unless it was voted down or is the original.
    static func pick(titles: [(String, Bool, Int, Bool)], thumbnails: [(Double?, Bool, Int, Bool)]) -> Branding {
        var out = Branding()
        if let t = titles.first(where: { $0.3 || $0.2 >= 0 }), !t.1 {
            // A leading ">" means "show exactly as written".
            var title = t.0.hasPrefix(">") ? String(t.0.dropFirst()) : t.0
            title = title.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { out.title = title }
        }
        if let th = thumbnails.first(where: { $0.3 || $0.2 >= 0 }), !th.1, let time = th.0 {
            out.thumbnailTime = time
        }
        return out
    }

    static func thumbnailURL(videoId: String, time: Double) -> URL? {
        var comps = URLComponents(string: "https://dearrow-thumb.ajay.app/api/v1/getThumbnail")!
        comps.queryItems = [URLQueryItem(name: "videoID", value: videoId), URLQueryItem(name: "time", value: String(time))]
        return comps.url
    }
}
