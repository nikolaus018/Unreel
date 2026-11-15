import Foundation

struct VideoItem: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var channelName: String?
    var channelId: String?
    var channelAvatar: URL?
    var duration: String?
    var views: String?
    var published: String?
    var isLive = false
    var isShort = false

    var thumbnail: URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }
    var smallThumbnail: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }
    var shareURL: URL { URL(string: "https://youtu.be/\(id)")! }

    /// "Channel · 1.2M views · 3 days ago"
    var subtitle: String {
        [channelName, views, published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ChannelItem: Identifiable, Hashable {
    let id: String
    var name: String
    var avatar: URL?
    var subtitle: String?
}

struct PlaylistItem: Identifiable, Hashable {
    let id: String
    var title: String
    var thumbnail: URL?
    var count: String?
    var owner: String?
}

enum FeedItem: Identifiable, Hashable {
    case video(VideoItem)
    case channel(ChannelItem)
    case playlist(PlaylistItem)

    var id: String {
        switch self {
        case .video(let v): "v:" + v.id
        case .channel(let c): "c:" + c.id
        case .playlist(let p): "p:" + p.id
        }
    }
}

struct FeedPage {
    var items: [FeedItem] = []
    var continuation: String?
}

struct WatchDetails {
    var videoId: String
    var title: String
    var views: String?
    var date: String?
    var likes: String?
    var description: String?
    var channel: ChannelItem?
    var related: [VideoItem] = []
    var relatedContinuation: String?
    var commentsToken: String?
    var commentsCount: String?
    var commentPreview: String?
}

struct Comment: Identifiable, Hashable {
    let id: String
    var author: String
    var avatar: URL?
    var text: String
    var likes: String?
    var published: String?
    var replies: Int
    var isPinned: Bool
    var isOwner: Bool
}

struct ChannelPage {
    var channel: ChannelItem
    var handle: String?
    var banner: URL?
    var details: [String] = []
    var tabs: [ChannelTab] = []
}

struct ChannelTab: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let params: String
}

struct Account: Equatable {
    var name: String
    var handle: String?
    var avatar: URL?
}

enum Route: Hashable {
    case channel(String)
    case playlist(String, String)    // id, title
    case browse(String, String)      // browseId, title (history, watch later, …)
}
