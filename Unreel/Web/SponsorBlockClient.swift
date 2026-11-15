import CryptoKit
import Foundation

/// Fetches crowd-sourced skip segments from the SponsorBlock API (sponsor.ajay.app).
/// Uses the privacy-preserving hash-prefix endpoint, so the server never learns the exact video.
actor SponsorBlockClient {
    struct Segment: Codable {
        let start: Double
        let end: Double
        let category: String
        let uuid: String
    }

    private struct APIVideo: Decodable {
        let videoID: String
        let segments: [APISegment]
    }
    private struct APISegment: Decodable {
        let category: String
        let actionType: String
        let segment: [Double]
        let UUID: String
    }

    private var cache: [String: (segments: [Segment], fetched: Date)] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    func segments(for videoID: String, categories: [String]) async -> [Segment] {
        guard videoID.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil, !categories.isEmpty else { return [] }
        let key = videoID + "|" + categories.joined(separator: ",")
        if let hit = cache[key], Date().timeIntervalSince(hit.fetched) < 1800 { return hit.segments }

        let digest = SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(digest.prefix(4))")!
        let categoriesJSON = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        components.queryItems = [
            URLQueryItem(name: "categories", value: categoriesJSON),
            URLQueryItem(name: "actionTypes", value: "[\"skip\"]"),
        ]
        guard let url = components.url else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return [] }
            if http.statusCode == 404 { cache[key] = ([], Date()); return [] }
            guard http.statusCode == 200 else { return [] }
            let videos = try JSONDecoder().decode([APIVideo].self, from: data)
            let segments = videos.first { $0.videoID == videoID }?.segments
                .filter { $0.actionType == "skip" && $0.segment.count == 2 }
                .map { Segment(start: $0.segment[0], end: $0.segment[1], category: $0.category, uuid: $0.UUID) } ?? []
            cache[key] = (segments, Date())
            return segments
        } catch {
            return []
        }
    }

    static func title(for category: String) -> String {
        SponsorCategory.all.first { $0.id == category }?.title.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "sponsors", with: "sponsor") ?? category
    }
}
