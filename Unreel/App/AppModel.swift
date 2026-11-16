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
    case home, subscriptions, you, search
}

/// App-wide state: what is playing, navigation per tab, the signed-in account and toasts.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let filters: FilterListManager
    let library: LocalLibrary
    let player: PlayerController

    @Published var tab: RootTab = .home
    @Published var homePath: [Route] = []
    @Published var subscriptionsPath: [Route] = []
    @Published var youPath: [Route] = []
    @Published var searchPath: [Route] = []

    @Published var showPlayer = false
    @Published private(set) var queue: PlayQueue?
    /// "Up next in N seconds" card shown when a video ends.
    @Published private(set) var upNext: (video: VideoItem, seconds: Int)?
    private var countdownTask: Task<Void, Never>?
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

    /// Video to add to a playlist (shows the playlist picker).
    @Published var addToPlaylist: VideoItem?
    private var progressCancellable: Any?
    private var lastProgressSave = Date.distantPast

    init(settings: AppSettings, filters: FilterListManager, library: LocalLibrary) {
        self.settings = settings
        self.filters = filters
        self.library = library
        self.player = PlayerController(settings: settings, filters: filters)
        player.onRateChosen = { [weak self] rate in
            guard let self, self.settings.rememberChannelSpeed,
                  let channel = self.watch?.channel ?? self.player.current?.channelId.map({ ChannelItem(id: $0, name: "") }) else { return }
            self.library.setSpeed(rate, for: channel.id, defaultSpeed: self.settings.defaultSpeed)
        }
        player.onSleep = { [weak self] in
            self?.cancelUpNext()
            self?.show(Toast(icon: "moon.zzz.fill", text: "Sleep timer paused the video"))
        }
        // Remember how far each video got (for resuming and hiding watched videos).
        progressCancellable = player.state.$time.sink { [weak self] _ in
            Task { @MainActor in self?.saveProgress() }
        }
        player.onEnded = { [weak self] in self?.videoEnded() }
        player.onNext = { [weak self] in self?.playNext() }
        player.onPrevious = { [weak self] in self?.playPrevious() }
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
    func play(_ video: VideoItem, queue: PlayQueue? = nil, at time: Double = 0) {
        haptic()
        self.queue = queue
        start(video, at: time)
        showPlayer = true
    }

    /// Where a video should start: the given time, or where it was left off.
    private func startTime(for video: VideoItem, requested: Double) -> Double {
        guard requested == 0, settings.resumePlayback, player.current?.id != video.id else { return requested }
        if let t = library.resumePosition(for: video.id) { return t }
        // YouTube's own marker (signed in), when the duration is known.
        if let p = video.progress, p > 0.03, p < 0.93, let d = video.duration.flatMap(Self.seconds(fromDuration:)), d > 120 {
            return (p * d).rounded()
        }
        return 0
    }

    /// "1:02:03" -> 3723
    nonisolated static func seconds(fromDuration text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.count == text.split(separator: ":").count else { return nil }
        return Double(parts.reduce(0) { $0 * 60 + $1 })
    }

    private func saveProgress(force: Bool = false) {
        let s = player.state
        guard let v = player.current, s.hasStarted, !s.isAd, s.duration > 0,
              force || s.ended || Date().timeIntervalSince(lastProgressSave) > 5 else { return }
        lastProgressSave = Date()
        var video = v
        if let w = watch, w.videoId == v.id {
            if !w.title.isEmpty { video.title = w.title }
            if let c = w.channel { video.channelId = c.id; video.channelName = c.name; video.channelAvatar = c.avatar ?? video.channelAvatar }
        }
        library.updateProgress(video, position: s.ended ? s.duration : s.time, duration: s.duration)
    }

    /// Plays the queue's item at `index` without opening the player.
    func jump(to index: Int) {
        guard var q = queue, q.items.indices.contains(index) else { return }
        haptic()
        q.index = index
        queue = q
        start(q.items[index])
    }

    private func start(_ video: VideoItem, at time: Double = 0) {
        cancelUpNext()
        saveProgress(force: true)
        let t = startTime(for: video, requested: time)
        let resumed = time == 0 && t > 0
        player.play(video, start: t)
        if settings.rememberChannelSpeed { player.applyPreferredRate(library.speed(for: video.channelId)) }
        loadWatch(video)
        if resumed {
            show(Toast(icon: "clock.arrow.circlepath", text: "Resumed at \(format(t))", actionTitle: "Start Over") { [weak self] in
                self?.player.seek(to: 0)
            })
        }
    }

    private func loadWatch(_ video: VideoItem) {
        watchTask?.cancel()
        if watch?.videoId != video.id {
            watch = WatchDetails(videoId: video.id, title: video.title, views: video.views, date: video.published,
                                 channel: video.channelId.map { ChannelItem(id: $0, name: video.channelName ?? "", avatar: video.channelAvatar) },
                                 isPlaceholder: true)
        }
        watchError = nil
        watchTask = Task {
            do {
                let json = try await InnerTube.shared.next(video.id)
                guard !Task.isCancelled else { return }
                var details = Parser.watch(json, videoId: video.id, hideShorts: settings.hideShorts)
                if details.title.isEmpty { details.title = video.title }
                // Nothing came back for this ID: the video is gone or private.
                if details.title.isEmpty && details.channel == nil && details.related.isEmpty {
                    watch = nil
                    watchError = "This video isn't available. It may have been removed or made private."
                    return
                }
                if details.channel == nil, let id = video.channelId {
                    details.channel = ChannelItem(id: id, name: video.channelName ?? "", avatar: video.channelAvatar)
                }
                if let c = details.channel {
                    if !signedIn { details.subscribed = library.isSubscribed(c.id) }
                    library.refresh(c)
                    if settings.rememberChannelSpeed, video.channelId != c.id { player.applyPreferredRate(library.speed(for: c.id)) }
                }
                watch = details
                if settings.returnDislike { loadDislikes(video.id) }
                player.state.chapters = details.chapters
                player.updateMetadata(title: details.title, channel: details.channel?.name)
            } catch {
                if !Task.isCancelled {
                    watchError = error.localizedDescription
                    // Don't leave the buttons greyed out forever: they still work without details.
                    watch?.isPlaceholder = false
                }
            }
        }
    }

    private func loadDislikes(_ id: String) {
        Task {
            guard let votes = await DislikeClient.shared.votes(for: id), watch?.videoId == id else { return }
            watch?.dislikes = votes.dislikes
            if watch?.likes == nil { watch?.likes = votes.likes.formatted(.number.notation(.compactName)) }
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

    /// What plays after the current video: the queue's next item, or the first recommendation.
    private func nextCandidate(automatic: Bool) -> VideoItem? {
        if let q = queue, q.hasNext { return q.items[q.index + 1] }
        if automatic && !settings.autoplayNext { return nil }
        return watch?.related.first(where: { !$0.isLive && library.allows(.video($0), hideWatched: settings.hideWatched) })
    }

    func playNext(automatic: Bool = false) {
        cancelUpNext()
        guard let next = nextCandidate(automatic: automatic) else { return }
        advance(to: next)
    }

    private func advance(to next: VideoItem) {
        if var q = queue, q.hasNext, q.items[q.index + 1] == next {
            q.index += 1
            queue = q
        } else {
            queue = nil
        }
        start(next)
    }

    /// A video finished: count down on screen, or continue right away in the background/PiP.
    private func videoEnded() {
        saveProgress(force: true)
        if player.state.sleepAtEnd { player.sleepNow(); return }
        guard let next = nextCandidate(automatic: true) else { return }
        let visible = showPlayer && UIApplication.shared.applicationState == .active && !player.state.pip
        guard visible else { advance(to: next); return }
        upNext = (next, 5)
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let u = self.upNext else { return }
                if u.seconds <= 1 { self.upNext = nil; self.advance(to: u.video); return }
                self.upNext = (u.video, u.seconds - 1)
            }
        }
    }

    func cancelUpNext() {
        countdownTask?.cancel()
        upNext = nil
    }

    func playUpNextNow() {
        guard let u = upNext else { return }
        cancelUpNext()
        advance(to: u.video)
    }

    /// Inserts a video right after the current one.
    func enqueueNext(_ video: VideoItem) {
        guard let current = player.current else { play(video); return }
        haptic()
        if var q = queue {
            q.items.removeAll { $0 == video }
            q.items.insert(video, at: min(q.index + 1, q.items.count))
            queue = q
        } else {
            queue = PlayQueue(title: "Queue", items: [current, video], index: 0)
        }
        show(Toast(icon: "text.line.first.and.arrowtriangle.forward", text: "Plays next"))
    }

    /// Previous in the queue, or back to the start when more than a few seconds in (like Music).
    func playPrevious() {
        if player.state.time > 3 || !(queue.map { $0.index > 0 } ?? false) {
            player.seek(to: 0)
            return
        }
        jump(to: (queue?.index ?? 1) - 1)
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
        haptic()
        guard signedIn else {
            // Without an account, subscriptions live on the device.
            library.setSubscribed(channel, subscribed)
            if watch?.channel?.id == channel.id { watch?.subscribed = subscribed }
            if subscribed { successHaptic() }
            show(Toast(icon: subscribed ? "bell.fill" : "bell.slash", text: subscribed ? "Subscribed to \(channel.name) on this device" : "Unsubscribed"))
            return
        }
        if watch?.channel?.id == channel.id { watch?.subscribed = subscribed }
        Task {
            do {
                try await InnerTube.shared.setSubscribed(channel.id, subscribed)
                if subscribed { successHaptic() }
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
                if saved { successHaptic() }
                show(Toast(icon: saved ? "clock.fill" : "clock", text: saved ? "Saved to Watch Later" : "Removed from Watch Later"))
            } catch {
                if saved { watchLater.remove(video.id) } else { watchLater.insert(video.id) }
                show(Toast(icon: "exclamationmark.triangle", text: "Couldn't update Watch Later"))
            }
        }
    }

    /// Opens the playlist picker for a video (signed in), or asks to sign in.
    func showAddToPlaylist(_ video: VideoItem) {
        guard requireSignIn() else { return }
        addToPlaylist = video
    }

    // MARK: Feed control

    func hide(_ video: VideoItem) {
        haptic()
        library.hide(video)
        show(Toast(icon: "eye.slash", text: "Video hidden", actionTitle: "Undo") { [weak self] in
            self?.library.unhide(video.id)
        })
    }

    func block(_ channel: ChannelItem) {
        haptic()
        library.block(channel)
        show(Toast(icon: "person.crop.circle.badge.xmark", text: "You won't see \(channel.name.isEmpty ? "this channel" : channel.name)", actionTitle: "Undo") { [weak self] in
            self?.library.unblock(channel.id)
        })
    }

    func closePlayer() {
        cancelUpNext()
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
                let t = comps?.queryItems?.first(where: { $0.name == "t" })?.value
                url = URL(string: "https://youtu.be/\(v)" + (t.map { "?t=\($0)" } ?? ""))!
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
            play(VideoItem(id: videoId, title: ""), at: Self.parseTimestamp(q("t") ?? q("start")))
            return
        }
        if let list = q("list") { open(.playlist(list, "Playlist")); return }
        if path.hasPrefix("/channel/"), let id = path.split(separator: "/").dropFirst().first { open(.channel(String(id))); return }
        // Anything else (@handles, /c/, /user/, custom URLs): ask YouTube what it points to.
        guard !path.isEmpty, path != "/" else { tab = .home; showPlayer = false; return }
        Task {
            let json = try? await InnerTube.shared.post("navigation/resolve_url", ["url": "https://www.youtube.com\(path)"])
            if let id = json?.first("browseEndpoint")["browseId"].string {
                if id.hasPrefix("VL") {
                    open(.playlist(String(id.dropFirst(2)), "Playlist"))
                } else if id.hasPrefix("UC") {
                    open(.channel(id))
                } else {
                    // Feed pages such as hashtags.
                    let title = path.split(separator: "/").last.map { $0.removingPercentEncoding ?? String($0) } ?? "YouTube"
                    open(.browse(id, title.hasPrefix("@") ? title : title.capitalized))
                }
            } else if let v = json?.first("watchEndpoint")["videoId"].string {
                play(VideoItem(id: v, title: ""))
            } else {
                show(Toast(icon: "link.badge.plus", text: "Couldn't open that link"))
            }
        }
    }

    /// Opens the first YouTube link found in pasted text. Returns false if there is none.
    @discardableResult
    func openYouTubeLink(in text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [URL] = []
        if let url = URL(string: trimmed) { candidates.append(url) }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            candidates += detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)).compactMap(\.url)
        }
        guard let url = candidates.first(where: { url in
            guard let host = url.host?.lowercased() else { return url.scheme == "unreel" }
            return host.hasSuffix("youtube.com") || host == "youtu.be"
        }) else {
            show(Toast(icon: "exclamationmark.circle", text: "That isn't a YouTube link"))
            return false
        }
        open(url: url)
        return true
    }

    /// "90", "90s", "1m30s", "1h2m3s" -> seconds.
    static func parseTimestamp(_ raw: String?) -> Double {
        guard let raw, !raw.isEmpty else { return 0 }
        if let n = Double(raw) { return n }
        var total = 0.0, number = ""
        for ch in raw {
            if ch.isNumber { number.append(ch); continue }
            let n = Double(number) ?? 0
            number = ""
            switch ch {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: break
            }
        }
        return total + (Double(number) ?? 0)
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
        // Give VoiceOver users time to hear the message and reach its action.
        var duration = toast.actionTitle == nil ? 2.4 : 4.5
        if UIAccessibility.isVoiceOverRunning { duration *= 2.5 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard self?.toast?.id == id else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }

    func haptic() {
        if settings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    /// Confirms a completed action (subscribe, save) with a success haptic.
    func successHaptic() {
        if settings.haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}
