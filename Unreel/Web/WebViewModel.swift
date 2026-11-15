import AVFoundation
import Combine
import SwiftUI
import WebKit
import os

enum AppTab: String, CaseIterable, Identifiable {
    case home, subscriptions, you
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .subscriptions: "Subscriptions"
        case .you: "You"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .subscriptions: "play.square.stack"
        case .you: "person.crop.circle"
        }
    }
    var selectedIcon: String {
        switch self {
        case .home: "house.fill"
        case .subscriptions: "play.square.stack.fill"
        case .you: "person.crop.circle.fill"
        }
    }
    var path: String {
        switch self {
        case .home: "/"
        case .subscriptions: "/feed/subscriptions"
        case .you: "/feed/you"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var icon: String
    var text: String
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// Owns the WKWebView and everything that connects it to the app.
@MainActor
final class WebViewModel: NSObject, ObservableObject {
    private let log = Logger(subsystem: "com.nikolaus.Unreel", category: "web")

    let settings: AppSettings
    let filters: FilterListManager
    private(set) var webView: WKWebView!

    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var selectedTab: AppTab = .home
    @Published private(set) var isWatchPage = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isFullscreen = false
    @Published private(set) var loadError: String?
    @Published private(set) var blockedThisSession = 0
    @Published private(set) var media: NowPlayingController.State?
    @Published var toast: Toast?
    @Published private(set) var suggestions: [String] = []
    private var suggestionTask: Task<Void, Never>?
    @Published var safariURL: URL?

    private var cancellables = Set<AnyCancellable>()
    private var observations: [NSKeyValueObservation] = []
    private let sponsorBlock = SponsorBlockClient()
    private let nowPlaying = NowPlayingController()
    private let refreshControl = UIRefreshControl()
    private var engineSource = ""
    private var lastAppliedConfig: [String: Any] = [:]
    private var reloadNeeded = false
    private var installedRuleLists: [WKContentRuleList] = []

    init(settings: AppSettings, filters: FilterListManager) {
        self.settings = settings
        self.filters = filters
        super.init()
        engineSource = Bundle.main.url(forResource: "engine", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        configureAudioSession()
        webView = makeWebView()
        observe()
        nowPlaying.onCommand = { [weak self] in self?.handleRemote($0) }
    }

    // MARK: Setup

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
        config.applicationNameForUserAgent = "Version/\(major).0 Mobile/15E148 Safari/604.1"
        config.defaultWebpagePreferences.preferredContentMode = settings.desktopSite ? .desktop : .mobile

        let controller = config.userContentController
        let proxy = MessageProxy(self)
        controller.add(proxy, contentWorld: .page, name: "unreel")
        controller.addScriptMessageHandler(proxy, contentWorld: .page, name: "unreelAsync")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = settings.swipeNavigation
        web.allowsLinkPreview = false
        web.isOpaque = false
        web.backgroundColor = .ytBackground
        web.scrollView.backgroundColor = .ytBackground
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        web.pageZoom = settings.pageZoom
        web.isInspectable = true
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        installScripts(on: controller)
        installRuleLists(on: controller)
        return web
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observe() {
        observations = [
            webView.observe(\.estimatedProgress, options: .new) { [weak self] w, _ in
                Task { @MainActor in self?.progress = w.estimatedProgress }
            },
            webView.observe(\.isLoading, options: .new) { [weak self] w, _ in
                Task { @MainActor in self?.isLoading = w.isLoading }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] w, _ in
                Task { @MainActor in self?.canGoBack = w.canGoBack }
            },
            webView.observe(\.url, options: .new) { [weak self] w, _ in
                Task { @MainActor in self?.urlChanged(w.url) }
            },
            webView.observe(\.fullscreenState, options: .new) { [weak self] w, _ in
                Task { @MainActor in self?.isFullscreen = w.fullscreenState == .inFullscreen || w.fullscreenState == .enteringFullscreen }
            },
        ]

        settings.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)

        filters.$contentRuleLists
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.installRuleLists(on: self.webView.configuration.userContentController)
            }
            .store(in: &cancellables)

        filters.$pageRules
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.installScripts(on: self.webView.configuration.userContentController)
                self.reloadNeeded = true
            }
            .store(in: &cancellables)
    }

    // MARK: Scripts and rules

    private func bootScript() -> String {
        let rules = (try? JSONEncoder().encode(settings.adBlocking ? filters.pageRules : PageRules()))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let config = (try? JSONSerialization.data(withJSONObject: settings.pageConfig))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.__unreelBoot={config:\(config),rules:\(rules)};\n" + engineSource
    }

    private func installScripts(on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        let script = WKUserScript(source: bootScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        controller.addUserScript(script)
        lastAppliedConfig = settings.pageConfig
    }

    private func installRuleLists(on controller: WKUserContentController) {
        #if DEBUG
        let debugOff = UserDefaults.standard.bool(forKey: "debug.noNetwork")
        #else
        let debugOff = false
        #endif
        let wanted = settings.adBlocking && !debugOff ? filters.contentRuleLists : []
        guard wanted.map(\.identifier) != installedRuleLists.map(\.identifier) || wanted.isEmpty != installedRuleLists.isEmpty else {
            // Same identifiers, but a rebuild replaces the compiled list objects.
            if !wanted.isEmpty, zip(wanted, installedRuleLists).contains(where: { $0 !== $1 }) {
                controller.removeAllContentRuleLists()
                wanted.forEach(controller.add)
                installedRuleLists = wanted
            }
            return
        }
        controller.removeAllContentRuleLists()
        wanted.forEach(controller.add)
        installedRuleLists = wanted
    }

    private func settingsChanged() {
        let controller = webView.configuration.userContentController
        let config = settings.pageConfig
        let oldConfig = lastAppliedConfig

        // Changes that only take effect on a fresh page load.
        for key in ["backgroundPlay", "listScriptlets", "adblock", "nativeTabBar"] {
            if (oldConfig[key] as? Bool) != (config[key] as? Bool) { reloadNeeded = true }
        }
        let desiredMode: WKWebpagePreferences.ContentMode = settings.desktopSite ? .desktop : .mobile
        if webView.configuration.defaultWebpagePreferences.preferredContentMode != desiredMode {
            webView.configuration.defaultWebpagePreferences.preferredContentMode = desiredMode
            reloadNeeded = true
        }

        installScripts(on: controller)
        installRuleLists(on: controller)
        if let json = try? JSONSerialization.data(withJSONObject: config), let s = String(data: json, encoding: .utf8) {
            webView.evaluateJavaScript("window.__unreel && window.__unreel.applyConfig(\(s))")
        }
        webView.allowsBackForwardNavigationGestures = settings.swipeNavigation
        if abs(webView.pageZoom - settings.pageZoom) > 0.001 { webView.pageZoom = settings.pageZoom }
        updateRefreshControl()
        nowPlaying.setEnabled(settings.lockScreenControls)
        if !settings.keepScreenOn { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// Called when the settings sheet closes: reload if a change needs a fresh page.
    func applyPendingReload() {
        guard reloadNeeded else { return }
        reloadNeeded = false
        if let url = webView.url, isInternal(url) {
            webView.load(URLRequest(url: rewriteForMode(url)))
        } else {
            loadStartPage()
        }
    }

    // MARK: Navigation

    var baseURL: URL { URL(string: settings.desktopSite ? "https://www.youtube.com" : "https://m.youtube.com")! }

    /// A link opened before the first page load (cold launch from a URL) replaces the start page.
    private var didInitialLoad = false
    private var pendingURL: URL?

    func loadStartPage() {
        didInitialLoad = true
        if let pending = pendingURL {
            pendingURL = nil
            open(pending)
            return
        }
        loadError = nil
        let url = baseURL.appendingPathComponent(String(settings.startPage.path.dropFirst()))
        webView.load(URLRequest(url: url))
    }

    func open(_ url: URL) {
        guard didInitialLoad else { pendingURL = url; return }
        loadError = nil
        if let internalURL = normalizedYouTubeURL(url) {
            webView.load(URLRequest(url: internalURL))
        } else if url.scheme == "http" || url.scheme == "https" {
            openExternally(url)
        }
    }

    func select(_ tab: AppTab) {
        if settings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        selectedTab = tab
        loadError = nil
        guard let url = webView.url, isInternal(url), webView.estimatedProgress > 0.3 else {
            webView.load(URLRequest(url: baseURL.appendingPathComponent(String(tab.path.dropFirst()))))
            return
        }
        webView.evaluateJavaScript("window.__unreel ? window.__unreel.navigate('\(tab.rawValue)') : 'missing'") { [weak self] result, _ in
            guard let self else { return }
            if (result as? String) == nil || (result as? String) == "missing" {
                self.webView.load(URLRequest(url: self.baseURL.appendingPathComponent(String(tab.path.dropFirst()))))
            }
        }
    }

    func openSearch() {
        webView.evaluateJavaScript("window.__unreel ? window.__unreel.openSearch() : false") { [weak self] result, _ in
            guard let self, (result as? Bool) != true else { return }
            self.webView.load(URLRequest(url: self.baseURL.appendingPathComponent("results")))
        }
    }

    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var comps = URLComponents(url: baseURL.appendingPathComponent("results"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "search_query", value: q)]
        if let url = comps.url { loadError = nil; webView.load(URLRequest(url: url)) }
        suggestions = []
    }

    /// Search suggestions from YouTube's public autocomplete endpoint.
    func updateSuggestions(for query: String) {
        suggestionTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { suggestions = []; return }
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            var comps = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
            comps.queryItems = [.init(name: "client", value: "firefox"), .init(name: "ds", value: "yt"), .init(name: "q", value: q)]
            guard let url = comps.url, let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count > 1, let list = json[1] as? [String], !Task.isCancelled else { return }
            self?.suggestions = Array(list.prefix(8))
        }
    }

    func scrollToTop() {
        webView.evaluateJavaScript("window.scrollTo({top: 0, behavior: 'smooth'})")
    }

    func togglePlayback() {
        if settings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        webView.evaluateJavaScript("window.__unreel && window.__unreel.toggle()")
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func reload() { loadError = nil; if webView.url == nil { loadStartPage() } else { webView.reload() } }

    func togglePiP() {
        webView.evaluateJavaScript("window.__unreel && window.__unreel.togglePiP()") { [weak self] result, _ in
            if (result as? String) == "no-video" {
                self?.show(Toast(icon: "pip", text: "Start a video to use Picture in Picture"))
            }
        }
    }

    /// A clean, shareable link for the current page (with the timestamp when a video is playing).
    var shareURL: URL? {
        guard let url = currentURL, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.host = "www.youtube.com"
        if comps.path == "/watch", let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
            var out = URLComponents(string: "https://youtu.be/\(v)")!
            if let t = media, t.videoId == v, t.time > 5 { out.queryItems = [URLQueryItem(name: "t", value: "\(Int(t.time))")] }
            return out.url
        }
        comps.queryItems = comps.queryItems?.filter { !["pp", "app", "persist_app", "noapp"].contains($0.name) }
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        return comps.url
    }

    private func urlChanged(_ url: URL?) {
        currentURL = url
        guard let url else { return }
        let path = url.path.isEmpty ? "/" : url.path
        isWatchPage = path == "/watch" || path.hasPrefix("/live/")
        if let tab = AppTab.allCases.first(where: { $0.path == path }) {
            selectedTab = tab
        } else if path.hasPrefix("/feed/library") || path.hasPrefix("/feed/history") || path.hasPrefix("/feed/playlists") {
            selectedTab = .you
        }
        updateRefreshControl()
    }

    private func updateRefreshControl() {
        let enabled = settings.pullToRefresh && !isWatchPage
        if enabled, webView.scrollView.refreshControl == nil { webView.scrollView.refreshControl = refreshControl }
        if !enabled, webView.scrollView.refreshControl != nil { webView.scrollView.refreshControl = nil }
    }

    @objc private func pullToRefresh() {
        webView.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshControl.endRefreshing() }
    }

    // MARK: URL rules

    static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    }

    /// Hosts that stay inside the app (YouTube and Google sign-in).
    func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if Self.isYouTubeHost(host) { return true }
        if host.range(of: "(^|\\.)google\\.[a-z.]{2,6}$", options: .regularExpression) != nil { return true }
        return host.hasSuffix("gstatic.com") || host.hasSuffix("googleusercontent.com")
    }

    /// Converts any YouTube link (youtu.be, shorts, www/m) into the URL the app should load.
    func normalizedYouTubeURL(_ url: URL) -> URL? {
        var url = url
        if url.scheme == "unreel" {
            // unreel://open?url=…  or  unreel://watch?v=…
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let inner = comps?.queryItems?.first(where: { $0.name == "url" })?.value, let innerURL = URL(string: inner) {
                url = innerURL
            } else {
                var c = URLComponents()
                c.scheme = "https"; c.host = "m.youtube.com"
                c.path = "/" + (comps?.host ?? "") + (comps?.path ?? "")
                c.queryItems = comps?.queryItems
                guard let u = c.url else { return nil }
                url = u
            }
        }
        if url.scheme == nil, let u = URL(string: "https://" + url.absoluteString) { url = u }
        guard let host = url.host?.lowercased(), Self.isYouTubeHost(host) else { return nil }
        return rewriteForMode(url)
    }

    private func rewriteForMode(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = comps.host?.lowercased() else { return url }
        if host == "youtu.be" {
            let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var items = [URLQueryItem(name: "v", value: id)]
            if let t = comps.queryItems?.first(where: { $0.name == "t" }) { items.append(t) }
            comps.path = "/watch"
            comps.queryItems = items
        }
        if settings.redirectShorts, comps.path.hasPrefix("/shorts/") {
            let id = comps.path.dropFirst("/shorts/".count).split(separator: "/").first.map(String.init) ?? ""
            comps.path = "/watch"
            comps.queryItems = [URLQueryItem(name: "v", value: id)]
        }
        if host == "youtu.be" || host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" {
            comps.host = settings.desktopSite ? "www.youtube.com" : "m.youtube.com"
        }
        comps.scheme = "https"
        comps.queryItems = comps.queryItems?.filter { !["app", "persist_app", "noapp"].contains($0.name) }
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        return comps.url ?? url
    }

    func openExternally(_ url: URL) {
        if settings.externalLinks == .inApp, url.scheme == "http" || url.scheme == "https" {
            safariURL = url
        } else {
            UIApplication.shared.open(url)
        }
    }

    // MARK: Lifecycle

    func sceneWillResignActive() {
        webView.evaluateJavaScript("window.__unreel ? window.__unreel.willResignActive() : false") { [weak self] result, _ in
            guard let self, (result as? Bool) == true, self.settings.autoPiP else { return }
            self.webView.evaluateJavaScript("window.__unreel.togglePiP()")
        }
    }

    func sceneDidEnterBackground() {
        guard settings.backgroundPlay else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.webView.evaluateJavaScript("window.__unreel && window.__unreel.resumeIfNeeded()")
            }
        }
    }

    func sceneDidBecomeActive() {
        webView.evaluateJavaScript("window.__unreel && window.__unreel.mediaState()")
    }

    // MARK: Toasts

    func show(_ toast: Toast) {
        withAnimation(.spring(duration: 0.35)) { self.toast = toast }
        let id = toast.id
        DispatchQueue.main.asyncAfter(deadline: .now() + (toast.actionTitle == nil ? 2.4 : 4.0)) { [weak self] in
            guard self?.toast?.id == id else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }

    // MARK: Messages from the page

    fileprivate func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "blocked":
            let n = body["count"] as? Int ?? 0
            blockedThisSession += n
            settings.adsBlockedTotal += n
        case "media":
            let state = NowPlayingController.State(
                videoId: body["videoId"] as? String,
                title: body["title"] as? String ?? "",
                author: body["author"] as? String ?? "",
                duration: body["duration"] as? Double ?? 0,
                time: body["time"] as? Double ?? 0,
                rate: body["rate"] as? Double ?? 1,
                playing: body["playing"] as? Bool ?? false)
            if media != state { media = state }
            isPlaying = state.playing
            if settings.keepScreenOn { UIApplication.shared.isIdleTimerDisabled = state.playing }
            if settings.lockScreenControls, !(body["isAd"] as? Bool ?? false) { nowPlaying.update(state) }
        case "video":
            if body["videoId"] is NSNull || body["videoId"] == nil {
                isPlaying = false
                media = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
        case "skipped":
            let seconds = body["seconds"] as? Int ?? 0
            settings.segmentsSkippedTotal += 1
            settings.secondsSavedTotal += seconds
            if settings.sponsorNotice {
                let category = SponsorBlockClient.title(for: body["category"] as? String ?? "")
                show(Toast(icon: "forward.fill", text: "Skipped \(category) · \(seconds)s", actionTitle: "Undo") { [weak self] in
                    self?.webView.evaluateJavaScript("window.__unreel && window.__unreel.undoSkip()")
                })
            }
        case "log":
            log.notice("page: \(body["message"] as? String ?? "", privacy: .public)")
        default:
            break
        }
    }

    fileprivate func handleAsync(_ body: [String: Any]) async -> Any? {
        guard body["type"] as? String == "sponsorblock", let id = body["videoId"] as? String, settings.sponsorBlock else { return [] }
        let segments = await sponsorBlock.segments(for: id, categories: settings.sponsorCategories.sorted())
        return segments.map { ["start": $0.start, "end": $0.end, "category": $0.category, "uuid": $0.uuid] }
    }

    private func handleRemote(_ command: NowPlayingController.Command) {
        let js: String
        switch command {
        case .play: js = "play()"
        case .pause: js = "pause()"
        case .toggle: js = "toggle()"
        case .seekBy(let s): js = "seekBy(\(s))"
        case .seekTo(let t): js = "seekTo(\(t))"
        case .next: js = "next()"
        case .previous: js = "previous()"
        }
        webView.evaluateJavaScript("window.__unreel && window.__unreel.\(js)")
    }

    // MARK: Data

    func clearCache() async {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeServiceWorkerRegistrations]
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
        show(Toast(icon: "checkmark.circle.fill", text: "Cache cleared"))
    }

    func clearAllData() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        loadStartPage()
        show(Toast(icon: "checkmark.circle.fill", text: "Signed out and cleared website data"))
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate

extension WebViewModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.cancel) }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        guard isMainFrame else { return decisionHandler(.allow) }

        if ["about", "blob", "data"].contains(scheme) { return decisionHandler(.allow) }
        guard scheme == "http" || scheme == "https" else {
            decisionHandler(.cancel)
            if ["mailto", "tel", "sms"].contains(scheme) { UIApplication.shared.open(url) }
            return
        }
        guard isInternal(url) else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated || action.targetFrame == nil { openExternally(url) }
            return
        }
        // YouTube's outbound link wrapper.
        if url.path == "/redirect", let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value,
           let target = URL(string: q) {
            decisionHandler(.cancel)
            openExternally(target)
            return
        }
        if let host = url.host?.lowercased(), Self.isYouTubeHost(host) {
            let rewritten = rewriteForMode(url)
            if rewritten != url, host == "youtu.be" || url.path.hasPrefix("/shorts/") {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: rewritten))
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        loadError = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        refreshControl.endRefreshing()
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }   // frame load interrupted / plugin
        loadError = ns.code == NSURLErrorNotConnectedToInternet ? "You're offline." : ns.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("Web content process terminated; reloading")
        webView.reload()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isInternal(url) { webView.load(URLRequest(url: url)) } else { openExternally(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        show(Toast(icon: "info.circle", text: message))
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        true
    }
}

// MARK: - Message handler proxy (avoids a retain cycle through WKUserContentController)

private final class MessageProxy: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    weak var model: WebViewModel?
    init(_ model: WebViewModel) { self.model = model }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { model?.handle(body) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any] else { replyHandler(nil, nil); return }
        MainActor.assumeIsolated {
            guard let model else { replyHandler(nil, nil); return }
            Task { @MainActor in
                let result = await model.handleAsync(body)
                replyHandler(result, nil)
            }
        }
    }
}

extension UIColor {
    /// YouTube's page background, so there is no white flash before the page paints.
    static let ytBackground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x0f / 255, green: 0x0f / 255, blue: 0x0f / 255, alpha: 1) : .white }
}
