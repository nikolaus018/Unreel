import SwiftUI

/// Everything Unreel remembers on the device, independent of a Google account: local
/// subscriptions, watch history and positions, hidden videos, blocked channels and keywords,
/// and the playback speed chosen per channel. Stored as one JSON file in Application Support.
@MainActor
final class LocalLibrary: ObservableObject {
    struct WatchRecord: Codable, Hashable {
        var video: VideoItem
        var position: Double
        var duration: Double
        var watchedAt: Date
        var fraction: Double { duration > 0 ? min(position / duration, 1) : 0 }
    }

    private struct Store: Codable {
        var subscriptions: [ChannelItem] = []
        var history: [WatchRecord] = []
        var hiddenVideos: [String] = []
        var blockedChannels: [ChannelItem] = []
        var blockedKeywords: [String] = []
        var channelSpeeds: [String: Double] = [:]
    }

    @Published private(set) var subscriptions: [ChannelItem] = []
    /// Most recent first.
    @Published private(set) var history: [WatchRecord] = []
    @Published private(set) var hiddenVideos: Set<String> = []
    @Published private(set) var blockedChannels: [ChannelItem] = []
    @Published private(set) var blockedKeywords: [String] = []
    @Published private(set) var channelSpeeds: [String: Double] = [:]
    /// Bumped whenever the filtering rules change, so feeds re-filter.
    @Published private(set) var filterGeneration = 0

    private var historyIndex: [String: Int] = [:]
    private let url: URL
    private var saveTask: Task<Void, Never>?
    private static let historyLimit = 2000

    init(fileName: String = "library.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(Store.self, from: data) {
            subscriptions = store.subscriptions
            history = store.history
            hiddenVideos = Set(store.hiddenVideos)
            blockedChannels = store.blockedChannels
            blockedKeywords = store.blockedKeywords
            channelSpeeds = store.channelSpeeds
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        historyIndex = Dictionary(history.enumerated().map { ($0.element.video.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
    }

    /// Writes shortly after the last change, off the main thread.
    private func save() {
        let store = Store(subscriptions: subscriptions, history: history, hiddenVideos: Array(hiddenVideos),
                          blockedChannels: blockedChannels, blockedKeywords: blockedKeywords, channelSpeeds: channelSpeeds)
        let url = url
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(store) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Subscriptions

    func isSubscribed(_ channelId: String) -> Bool { subscriptions.contains { $0.id == channelId } }

    func setSubscribed(_ channel: ChannelItem, _ on: Bool) {
        subscriptions.removeAll { $0.id == channel.id }
        if on {
            var c = channel
            c.subtitle = nil
            subscriptions.append(c)
            subscriptions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        save()
    }

    /// Fills in a missing name or avatar for a channel already subscribed to.
    func refresh(_ channel: ChannelItem) {
        guard let i = subscriptions.firstIndex(where: { $0.id == channel.id }) else { return }
        var c = subscriptions[i]
        var changed = false
        if c.name.isEmpty, !channel.name.isEmpty { c.name = channel.name; changed = true }
        if channel.avatar != nil, c.avatar != channel.avatar { c.avatar = channel.avatar; changed = true }
        guard changed else { return }
        subscriptions[i] = c
        save()
    }

    /// Imports a Google Takeout `subscriptions.csv` (Channel Id, Channel Url, Channel Title).
    /// Returns how many channels were added.
    @discardableResult
    func importSubscriptions(csv: String) -> Int {
        var added = 0
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = Self.csvFields(String(line))
            guard let id = fields.first?.trimmingCharacters(in: .whitespaces), id.hasPrefix("UC"), !isSubscribed(id) else { continue }
            let name = fields.count > 2 ? fields[2] : ""
            subscriptions.append(ChannelItem(id: id, name: name))
            added += 1
        }
        subscriptions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if added > 0 { save() }
        return added
    }

    /// A Takeout-compatible CSV of the local subscriptions.
    func exportSubscriptionsCSV() -> String {
        func q(_ s: String) -> String { s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        let rows = subscriptions.map { "\($0.id),http://www.youtube.com/channel/\($0.id),\(q($0.name))" }
        return (["Channel Id,Channel Url,Channel Title"] + rows).joined(separator: "\n") + "\n"
    }

    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        var it = Array(line)[...]
        while let ch = it.popFirst() {
            if quoted {
                if ch == "\"" {
                    if it.first == "\"" { current.append("\""); it.removeFirst() } else { quoted = false }
                } else { current.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { fields.append(current); current = "" }
            else { current.append(ch) }
        }
        fields.append(current)
        return fields
    }

    // MARK: History and positions

    func record(for videoId: String) -> WatchRecord? { historyIndex[videoId].map { history[$0] } }

    /// Remembers how far a video got. Called periodically while it plays.
    func updateProgress(_ video: VideoItem, position: Double, duration: Double) {
        guard duration > 0, position >= 0, !video.id.isEmpty else { return }
        var v = video
        v.progress = nil
        if let i = historyIndex[video.id] {
            var r = history[i]
            if v.title.isEmpty { v.title = r.video.title }
            if v.channelName == nil { v.channelName = r.video.channelName; v.channelId = r.video.channelId }
            r.video = v
            r.position = position
            r.duration = duration
            r.watchedAt = Date()
            if i == 0 { history[0] = r } else { history.remove(at: i); history.insert(r, at: 0) }
        } else {
            if v.duration == nil { v.duration = format(duration) }
            history.insert(WatchRecord(video: v, position: position, duration: duration, watchedAt: Date()), at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        }
        rebuildIndex()
        save()
    }

    /// Where to pick up a video: nil when it was barely started or nearly finished.
    func resumePosition(for videoId: String) -> Double? {
        guard let r = record(for: videoId), r.position > 20, r.duration - r.position > 25, r.fraction < 0.95 else { return nil }
        return r.position
    }

    /// How much of a video was watched, from YouTube's own marker or local history.
    func watchedFraction(_ video: VideoItem) -> Double {
        max(video.progress ?? 0, record(for: video.id)?.fraction ?? 0)
    }

    func removeFromHistory(_ ids: [String]) {
        let set = Set(ids)
        history.removeAll { set.contains($0.video.id) }
        rebuildIndex()
        filterGeneration += 1
        save()
    }

    func clearHistory() {
        history = []
        rebuildIndex()
        filterGeneration += 1
        save()
    }

    // MARK: Hiding and blocking

    func hide(_ video: VideoItem) {
        hiddenVideos.insert(video.id)
        filterGeneration += 1
        save()
    }

    func unhide(_ id: String) {
        hiddenVideos.remove(id)
        filterGeneration += 1
        save()
    }

    func unhideAll() {
        hiddenVideos = []
        filterGeneration += 1
        save()
    }

    func isBlocked(channelId: String?, name: String?) -> Bool {
        blockedChannels.contains { c in
            if let channelId, c.id == channelId { return true }
            if let name, !name.isEmpty, c.name.caseInsensitiveCompare(name) == .orderedSame { return true }
            return false
        }
    }

    func block(_ channel: ChannelItem) {
        guard !blockedChannels.contains(where: { $0.id == channel.id }) else { return }
        var c = channel
        c.subtitle = nil
        blockedChannels.append(c)
        blockedChannels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        filterGeneration += 1
        save()
    }

    func unblock(_ channelId: String) {
        blockedChannels.removeAll { $0.id == channelId }
        filterGeneration += 1
        save()
    }

    func addKeyword(_ raw: String) {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !blockedKeywords.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) else { return }
        blockedKeywords.append(k)
        filterGeneration += 1
        save()
    }

    func removeKeywords(at offsets: IndexSet) {
        blockedKeywords.remove(atOffsets: offsets)
        filterGeneration += 1
        save()
    }

    /// Whether a title contains a blocked keyword (whole words, case and accent insensitive).
    func matchesKeyword(_ title: String) -> Bool {
        guard !blockedKeywords.isEmpty, !title.isEmpty else { return false }
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return blockedKeywords.contains { k in
            let key = k.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard let range = folded.range(of: key) else { return false }
            // Require word boundaries so "art" doesn't hide "start".
            let before = range.lowerBound == folded.startIndex ? nil : folded[folded.index(before: range.lowerBound)]
            let after = range.upperBound == folded.endIndex ? nil : folded[range.upperBound]
            let boundary: (Character?) -> Bool = { c in c.map { !$0.isLetter && !$0.isNumber } ?? true }
            return boundary(before) && boundary(after)
        }
    }

    /// The filter feeds use. `hideWatched` only applies on discovery feeds (Home, Subscriptions, Up Next).
    func allows(_ item: FeedItem, hideWatched: Bool) -> Bool {
        switch item {
        case .video(let v):
            if hiddenVideos.contains(v.id) { return false }
            if isBlocked(channelId: v.channelId, name: v.channelName) { return false }
            if matchesKeyword(v.title) { return false }
            if hideWatched, watchedFraction(v) >= 0.9 { return false }
            return true
        case .channel(let c):
            return !blockedChannels.contains { $0.id == c.id }
        case .playlist(let p):
            return !matchesKeyword(p.title)
        }
    }

    // MARK: Speed per channel

    func speed(for channelId: String?) -> Double? { channelId.flatMap { channelSpeeds[$0] } }

    func setSpeed(_ speed: Double, for channelId: String, defaultSpeed: Double) {
        if abs(speed - defaultSpeed) < 0.01 { channelSpeeds[channelId] = nil } else { channelSpeeds[channelId] = speed }
        save()
    }

    func clearSpeeds() {
        channelSpeeds = [:]
        save()
    }
}
