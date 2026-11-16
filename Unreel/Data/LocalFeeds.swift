import Foundation

/// Feeds built on the device for people who don't sign in: the newest uploads of locally
/// subscribed channels, and a Home feed mixed from those and from what was watched recently.
actor LocalFeeds {
    static let shared = LocalFeeds()

    /// Channel "Videos" tab (no Shorts, no live).
    static let videosTab = "EgZ2aWRlb3PyBgQKAjoA"

    private var channelCache: [String: (videos: [VideoItem], fetched: Date)] = [:]
    private var relatedCache: [String: [VideoItem]] = [:]

    /// Newest uploads across the channels, newest first.
    func subscriptions(_ channels: [ChannelItem], hideShorts: Bool, perChannel: Int = 12, force: Bool = false) async throws -> [VideoItem] {
        guard !channels.isEmpty else { return [] }
        var results: [(Int, [VideoItem])] = []
        var failures = 0
        // A handful of requests at a time, so a long list doesn't hammer YouTube.
        try await withThrowingTaskGroup(of: (Int, [VideoItem]?).self) { group in
            var next = 0
            func addTask() {
                guard next < channels.count else { return }
                let i = next
                let channel = channels[i]
                next += 1
                group.addTask { (i, await self.videos(of: channel, hideShorts: hideShorts, force: force)) }
            }
            for _ in 0..<6 { addTask() }
            while let (i, list) = try await group.next() {
                if let list { results.append((i, Array(list.prefix(perChannel)))) } else { failures += 1 }
                addTask()
            }
        }
        if results.isEmpty && failures > 0 { throw InnerTube.APIError.message("Couldn't reach YouTube.") }
        // Sort by age; ties (and unparseable dates) keep channel order.
        let all = results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        return all.enumerated()
            .sorted { a, b in
                let x = Self.age(of: a.element.published), y = Self.age(of: b.element.published)
                return x == y ? a.offset < b.offset : x < y
            }
            .map(\.element)
    }

    private func videos(of channel: ChannelItem, hideShorts: Bool, force: Bool) async -> [VideoItem]? {
        if !force, let hit = channelCache[channel.id], Date().timeIntervalSince(hit.fetched) < 600 { return hit.videos }
        guard let json = try? await InnerTube.shared.browse(channel.id, params: Self.videosTab) else { return channelCache[channel.id]?.videos }
        var name = channel.name
        if name.isEmpty { name = Parser.channelPage(json, id: channel.id).channel.name }
        let avatar = channel.avatar ?? Parser.channelPage(json, id: channel.id).channel.avatar
        let list: [VideoItem] = Parser.feed(json, hideShorts: hideShorts).items.compactMap {
            guard case .video(var v) = $0, !v.isLive else { return nil }
            // Lockups on channel pages don't repeat the channel.
            if v.channelId == nil { v.channelId = channel.id }
            if v.channelName == nil || v.channelName?.isEmpty == true { v.channelName = name }
            if v.channelAvatar == nil { v.channelAvatar = avatar }
            return v
        }
        channelCache[channel.id] = (list, Date())
        return list
    }

    /// Home without an account: recommendations next to recently watched videos, mixed with
    /// new uploads from local subscriptions.
    func home(recent: [VideoItem], channels: [ChannelItem], hideShorts: Bool, exclude: Set<String>) async -> [VideoItem] {
        var related: [[VideoItem]] = []
        await withTaskGroup(of: (Int, [VideoItem]).self) { group in
            for (i, v) in recent.prefix(5).enumerated() {
                group.addTask { (i, await self.related(to: v.id, hideShorts: hideShorts)) }
            }
            var out: [(Int, [VideoItem])] = []
            for await r in group { out.append(r) }
            related = out.sorted { $0.0 < $1.0 }.map { Array($0.1.prefix(12)) }
        }
        let uploads = (try? await subscriptions(channels, hideShorts: hideShorts, perChannel: 3)) ?? []
        var lists = related
        if !uploads.isEmpty { lists.insert(Array(uploads.prefix(30)), at: 0) }

        // Round-robin so no single source dominates the top of the feed.
        var seen = exclude
        var feed: [VideoItem] = []
        var index = 0
        while lists.contains(where: { index < $0.count }) {
            for list in lists where index < list.count {
                let v = list[index]
                if !v.isLive, seen.insert(v.id).inserted { feed.append(v) }
            }
            index += 1
        }
        return feed
    }

    private func related(to id: String, hideShorts: Bool) async -> [VideoItem] {
        if let hit = relatedCache[id] { return hit }
        guard let json = try? await InnerTube.shared.next(id) else { return [] }
        let list = Parser.watch(json, videoId: id, hideShorts: hideShorts).related
        relatedCache[id] = list
        return list
    }

    func clearCache() {
        channelCache = [:]
        relatedCache = [:]
    }

    // MARK: Relative dates

    private static let units: [(stems: [String], seconds: Double)] = [
        (["second", "sekunde", "seconde", "segundo", "secondo", "sec"], 1),
        (["minute", "minuto", "min"], 60),
        (["hour", "stunde", "heure", "hora", "ora"], 3600),
        (["day", "tag", "jour", "día", "dia", "giorn"], 86_400),
        (["week", "woche", "semaine", "semana", "settiman"], 604_800),
        (["month", "monat", "mois", "mes"], 2_592_000),
        (["year", "jahr", "an", "año", "ano", "anno"], 31_536_000),
    ]

    /// Approximate age in seconds of "3 days ago" / "vor 3 Tagen" / "Streamed 2 weeks ago".
    /// Unknown text sorts last.
    static func age(of text: String?) -> Double {
        guard let text = text?.lowercased(), !text.isEmpty else { return .infinity }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for (i, w) in words.enumerated() {
            guard let n = Double(w) else { continue }
            // The unit is the word right after the number.
            guard i + 1 < words.count else { continue }
            let unit = words[i + 1]
            // Longest stems first, so "minute" isn't read as "min" + garbage and "an" doesn't match "hour".
            for (stems, seconds) in units {
                if stems.contains(where: { stem in stem.count >= 3 ? unit.hasPrefix(stem) : unit == stem || unit == stem + "s" || unit == stem + "nées" }) {
                    return n * seconds
                }
            }
        }
        return .infinity
    }
}
