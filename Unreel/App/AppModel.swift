import SwiftUI
import WebKit

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var icon: String
    var text: String
    var actionTitle: String?
    var action: (() -> Void)?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

enum RootTab: Hashable {
    case home, subscriptions, you, settings, search
}

/// App-wide state: what is playing, navigation per tab, the signed-in account and toasts.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let filters: FilterListManager
    let player: PlayerController

    @Published var tab: RootTab = .home
    @Published var homePath: [Route] = []
    @Published var subscriptionsPath: [Route] = []
    @Published var youPath: [Route] = []
    @Published var searchPath: [Route] = []

    @Published var showPlayer = false
    @Published private(set) var queue: PlayQueue?
    @Published private(set) var watch: WatchDetails?
    @Published private(set) var watchError: String?
    @Published private(set) var account: Account?
    @Published private(set) var signedIn = false
    @Published var showSignIn = false
    @Published var toast: Toast?
    @Published var blockedThisSession = 0

    /// Bumped when the account changes so feeds reload.
    @Published private(set) var feedGeneration = 0

    private var watchTask: Task<Void, Never>?

    init(settings: AppSettings, filters: FilterListManager) {
        self.settings = settings
        self.filters = filters
        self.player = PlayerController(settings: settings, filters: filters)
        player.onEnded = { [weak self] in self?.playNext(automatic: true) }
        player.onPiPUnavailable = { [weak self] in
            self?.show(Toast(icon: "pip", text: "Picture in Picture isn't available here"))
        }
        player.onBlocked = { [weak self] n in
            guard let self else { return }
            self.blockedThisSession += n
            self.settings.adsBlockedTotal += n
        }
        player.onSkippedSegment = { [weak self] category, seconds in
            guard let self else { return }
            self.settings.segmentsSkippedTotal += 1
            self.settings.secondsSavedTotal += seconds
            if self.settings.sponsorNotice {
                let name = SponsorBlockClient.title(for: category)
                self.show(Toast(icon: "forward.fill", text: "Skipped \(name) · \(seconds)s", actionTitle: "Undo") { [weak self] in
                    self?.player.undoSkip()
                })
            }
        }
    }

    // MARK: Playback

    /// Plays a video; with a queue, Next and autoplay follow the queue instead of recommendations.
    func play(_ video: VideoItem, queue: PlayQueue? = nil) {
        haptic()
        self.queue = queue
        start(video)
        showPlayer = true
    }

    /// Plays the queue's item at `index` without opening the player.
    func jump(to index: Int) {
        guard var q = queue, q.items.indices.contains(index) else { return }
        haptic()
        q.index = index
        queue = q
        start(q.items[index])
    }

    private func start(_ video: VideoItem) {
        player.play(video)
        loadWatch(video)
    }

    private func loadWatch(_ video: VideoItem) {
        watchTask?.cancel()
        if watch?.videoId != video.id {
            watch = WatchDetails(videoId: video.id, title: video.title, views: video.views, date: video.published,
                                 channel: video.channelId.map { ChannelItem(id: $0, name: video.channelName ?? "", avatar: video.channelAvatar) })
        }
        watchError = nil
        watchTask = Task {
            do {
                let json = try await InnerTube.shared.next(video.id)
                guard !Task.isCancelled else { return }
                var details = Parser.watch(json, videoId: video.id, hideShorts: settings.hideShorts)
                if details.title.isEmpty { details.title = video.title }
                if details.channel == nil, let id = video.channelId {
                    details.channel = ChannelItem(id: id, name: video.channelName ?? "", avatar: video.channelAvatar)
                }
                watch = details
                player.updateMetadata(title: details.title, channel: details.channel?.name)
            } catch {
                if !Task.isCancelled { watchError = error.localizedDescription }
            }
        }
    }

    func loadMoreRelated() async {
        guard let w = watch, let token = w.relatedContinuation else { return }
        guard let json = try? await InnerTube.shared.continuation("next", token: token) else { return }
        let page = Parser.feed(json, hideShorts: settings.hideShorts)
        guard watch?.videoId == w.videoId else { return }
        let more = page.items.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
        let existing = Set(w.related.map(\.id))
        watch?.related += more.filter { !existing.contains($0.id) }
        watch?.relatedContinuation = page.continuation
    }

    /// `automatic` is true when a video ended on its own (respects the Autoplay setting).
    func playNext(automatic: Bool = false) {
        if var q = queue, q.hasNext {
            q.index += 1
            queue = q
            start(q.items[q.index])
            return
        }
        if automatic && !settings.autoplayNext { return }
        guard let next = watch?.related.first(where: { !$0.isLive }) else { return }
        queue = nil
        start(next)
    }

    var canPlayNext: Bool { (queue?.hasNext ?? false) || !(watch?.related.isEmpty ?? true) }

    // MARK: Signed-in actions (optimistic: update the UI first, roll back on failure)

    @Published private(set) var watchLater: Set<String> = []

    private func requireSignIn() -> Bool {
        guard signedIn else {
            show(Toast(icon: "person.crop.circle.badge.exclamationmark", text: "Sign in to do that", actionTitle: "Sign In") { [weak self] in
                self?.showSignIn = true
            })
            return false
        }
        return true
    }

    func rate(_ target: LikeStatus) {
        guard requireSignIn(), let w = watch else { return }
        haptic()
        let previous = w.likeStatus
        let new: LikeStatus = previous == target ? .none : target
        watch?.likeStatus = new
        Task {
            do {
                let rating: InnerTube.Rating = new == .liked ? .like : new == .disliked ? .dislike : .removelike
                try await InnerTube.shared.rate(w.videoId, rating)
            } catch {
                if watch?.videoId == w.videoId { watch?.likeStatus = previous }
                show(Toast(icon: "exclamationmark.triangle", text: "Couldn't save your rating"))
            }
        }
    }

    /// Returns the new state immediately; reverts through `onFailure` if the request fails.
    func setSubscribed(_ channel: ChannelItem, _ subscribed: Bool, onFailure: @escaping () -> Void = {}) {
        guard requireSignIn() else { onFailure(); return }
        haptic()
        if watch?.channel?.id == channel.id { watch?.subscribed = subscribed }
        Task {
            do {
                try await InnerTube.shared.setSubscribed(channel.id, subscribed)
                show(Toast(icon: subscribed ? "bell.fill" : "bell.slash", text: subscribed ? "Subscribed to \(channel.name)" : "Unsubscribed"))
            } catch {
                if watch?.channel?.id == channel.id { watch?.subscribed = !subscribed }
                onFailure()
                show(Toast(icon: "exclamationmark.triangle", text: "Couldn't change your subscription"))
            }
        }
    }

    func toggleWatchLater(_ video: VideoItem) {
        guard requireSignIn() else { return }
        haptic()
        let saved = !watchLater.contains(video.id)
        if saved { watchLater.insert(video.id) } else { watchLater.remove(video.id) }
        Task {
            do {
                try await InnerTube.shared.setWatchLater(video.id, saved)
                show(Toast(icon: saved ? "clock.fill" : "clock", text: saved ? "Saved to Watch Later" : "Removed from Watch Later"))
            } catch {
                if saved { watchLater.remove(video.id) } else { watchLater.insert(video.id) }
                show(Toast(icon: "exclamationmark.triangle", text: "Couldn't update Watch Later"))
            }
        }
    }

    func closePlayer() {
        player.stop()
        showPlayer = false
        watch = nil
        queue = nil
    }

    // MARK: Navigation

    func open(_ route: Route) {
        showPlayer = false
        switch tab {
        case .home: homePath.append(route)
        case .subscriptions: subscriptionsPath.append(route)
        case .you: youPath.append(route)
        case .search: searchPath.append(route)
        case .settings:
            tab = .home
            homePath.append(route)
        }
    }

    /// Handles youtube.com / youtu.be links and `unreel://` links.
    func open(url: URL) {
        var url = url
        if url.scheme == "unreel" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let inner = comps?.queryItems?.first(where: { $0.name == "url" })?.value, let u = URL(string: inner) {
                url = u
            } else if let v = comps?.queryItems?.first(where: { $0.name == "v" })?.value {
                url = URL(string: "https://youtu.be/\(v)")!
            }
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = comps.host?.lowercased() else { return }
        let path = comps.path
        let q = { (name: String) in comps.queryItems?.first(where: { $0.name == name })?.value }
        var videoId: String?
        if host == "youtu.be" { videoId = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        else if path == "/watch" { videoId = q("v") }
        else if path.hasPrefix("/shorts/") || path.hasPrefix("/live/") || path.hasPrefix("/embed/") {
            videoId = path.split(separator: "/").dropFirst().first.map(String.init)
        }
        if let videoId, !videoId.isEmpty {
            play(VideoItem(id: videoId, title: ""))
            return
        }
        if let list = q("list") { open(.playlist(list, "Playlist")); return }
        if path.hasPrefix("/channel/"), let id = path.split(separator: "/").dropFirst().first { open(.channel(String(id))); return }
        if path.hasPrefix("/@") {
            Task {
                if let json = try? await InnerTube.shared.post("navigation/resolve_url", ["url": "https://www.youtube.com\(path)"]),
                   let id = json.first("browseEndpoint")["browseId"].string {
                    open(.channel(id))
                }
            }
        }
    }

    // MARK: Account

    func refreshAccount() async {
        let cookies = await InnerTube.youtubeCookies()
        signedIn = InnerTube.isSignedIn(cookies)
        guard signedIn else { account = nil; return }
        if let json = try? await InnerTube.shared.accountMenu() { account = Parser.account(json) }
    }

    func didSignIn() async {
        await InnerTube.shared.reset()
        await refreshAccount()
        feedGeneration += 1
        if signedIn { show(Toast(icon: "person.crop.circle.badge.checkmark", text: "Signed in" + (account.map { " as \($0.name)" } ?? ""))) }
    }

    func signOut() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await InnerTube.installConsentCookie()
        await InnerTube.shared.reset()
        await refreshAccount()
        feedGeneration += 1
        show(Toast(icon: "checkmark.circle.fill", text: "Signed out and cleared website data"))
    }

    func clearCache() async {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        show(Toast(icon: "checkmark.circle.fill", text: "Cache cleared"))
    }

    // MARK: Feedback

    func show(_ toast: Toast) {
        withAnimation(.spring(duration: 0.35)) { self.toast = toast }
        let id = toast.id
        DispatchQueue.main.asyncAfter(deadline: .now() + (toast.actionTitle == nil ? 2.4 : 4.0)) { [weak self] in
            guard self?.toast?.id == id else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }

    func haptic() {
        if settings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
}
