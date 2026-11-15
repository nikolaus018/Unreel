import AVFoundation
import Combine
import SwiftUI
import WebKit
import os

/// Fast-changing playback state, kept apart so only the player UI re-renders 4× a second.
@MainActor
final class PlaybackState: ObservableObject {
    @Published var playing = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var buffered: Double = 0
    @Published var rate: Double = 1
    @Published var waiting = true
    @Published var isAd = false
    @Published var ended = false
    @Published var pip = false
    @Published var levels: [String] = []
    @Published var quality = ""
    @Published var pageLoading = false
}

/// Plays videos with YouTube's own web player inside a web view that shows nothing but the video.
/// Ads are removed from the player's data before it reads them (see engine.js); every control
/// on screen is native.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    private let log = Logger(subsystem: "com.nikolaus.Unreel", category: "player")

    let settings: AppSettings
    let filters: FilterListManager
    let state = PlaybackState()
    private(set) var webView: WKWebView!

    @Published private(set) var current: VideoItem?

    var onEnded: (() -> Void)?
    var onSkippedSegment: ((String, Int) -> Void)?
    var onPiPUnavailable: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private let sponsorBlock = SponsorBlockClient()
    private let nowPlaying = NowPlayingController()
    private var engineSource = ""
    private var installedRuleLists: [WKContentRuleList] = []
    private var reloadNeeded = false
    private var pageReady = false
    private var lastConfigJSON = ""
    private let parking = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))

    init(settings: AppSettings, filters: FilterListManager) {
        self.settings = settings
        self.filters = filters
        super.init()
        engineSource = Bundle.main.url(forResource: "engine", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        webView = makeWebView()
        parking.isUserInteractionEnabled = false
        parking.alpha = 0.02
        parking.addSubview(webView)
        webView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        nowPlaying.onCommand = { [weak self] in self?.handleRemote($0) }
        observe()
    }

    // MARK: Web view

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
        config.applicationNameForUserAgent = "Version/\(major).0 Mobile/15E148 Safari/604.1"

        let controller = config.userContentController
        let proxy = MessageProxy(self)
        controller.add(proxy, contentWorld: .page, name: "unreel")
        controller.addScriptMessageHandler(proxy, contentWorld: .page, name: "unreelAsync")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isUserInteractionEnabled = false
        web.isInspectable = true
        installScripts(on: controller)
        installRuleLists(on: controller)
        return web
    }

    /// The view the player can rest in while no player screen is visible (keeps playback alive).
    var parkingView: UIView { parking }

    /// Moves the video surface into `container`, filling it.
    func attach(to container: UIView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// Returns the surface to the parking spot if it is still inside `container`.
    func detach(from container: UIView) {
        guard webView.superview === container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        parking.addSubview(webView)
    }

    private var pageConfig: [String: Any] {
        var c = settings.pageConfig
        c["playerMode"] = true
        c["nativeTabBar"] = false
        c["hideShorts"] = false
        c["redirectShorts"] = false
        return c
    }

    private func bootScript() -> String {
        let rules = (try? JSONEncoder().encode(settings.adBlocking ? filters.pageRules : PageRules()))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let config = (try? JSONSerialization.data(withJSONObject: pageConfig)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.__unreelBoot={config:\(config),rules:\(rules)};\n" + engineSource
    }

    private func installScripts(on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: bootScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    private func installRuleLists(on controller: WKUserContentController) {
        #if DEBUG
        let debugOff = UserDefaults.standard.bool(forKey: "debug.noNetwork")
        #else
        let debugOff = false
        #endif
        let wanted = settings.adBlocking && !debugOff ? filters.contentRuleLists : []
        let same = wanted.count == installedRuleLists.count && zip(wanted, installedRuleLists).allSatisfy { $0 === $1 }
        guard !same else { return }
        controller.removeAllContentRuleLists()
        wanted.forEach(controller.add)
        installedRuleLists = wanted
    }

    private func observe() {
        settings.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)
        filters.$contentRuleLists.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in guard let self else { return }; self.installRuleLists(on: self.webView.configuration.userContentController) }
            .store(in: &cancellables)
        filters.$pageRules.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in guard let self else { return }; self.installScripts(on: self.webView.configuration.userContentController); self.reloadNeeded = true }
            .store(in: &cancellables)
    }

    private func settingsChanged() {
        let controller = webView.configuration.userContentController
        let json = (try? JSONSerialization.data(withJSONObject: pageConfig)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard json != lastConfigJSON else { return }
        if !lastConfigJSON.isEmpty, settingsNeedReload(old: lastConfigJSON, new: json) { reloadNeeded = true }
        lastConfigJSON = json
        installScripts(on: controller)
        installRuleLists(on: controller)
        webView.evaluateJavaScript("window.__unreel && window.__unreel.applyConfig(\(json))")
        nowPlaying.setEnabled(settings.lockScreenControls)
        if !settings.keepScreenOn { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func settingsNeedReload(old: String, new: String) -> Bool {
        let a = (try? JSONSerialization.jsonObject(with: Data(old.utf8))) as? [String: Any] ?? [:]
        let b = (try? JSONSerialization.jsonObject(with: Data(new.utf8))) as? [String: Any] ?? [:]
        return ["adblock", "listScriptlets", "backgroundPlay"].contains { (a[$0] as? Bool) != (b[$0] as? Bool) }
    }

    /// Applies changes that need a fresh page, keeping the position in the current video.
    func applyPendingReload() {
        guard reloadNeeded, let current else { reloadNeeded = false; return }
        reloadNeeded = false
        load(current.id, start: state.time)
    }

    // MARK: Playback

    func play(_ video: VideoItem, start: Double = 0) {
        if current?.id == video.id {
            if !state.playing { togglePlay() }
            return
        }
        current = video
        state.time = start
        state.duration = 0
        state.buffered = 0
        state.ended = false
        state.waiting = true
        state.isAd = false
        load(video.id, start: start)
        updateNowPlaying()
    }

    private func load(_ id: String, start: Double) {
        let startArg = start > 1 ? "\(Int(start))" : "0"
        if pageReady, webView.url?.path == "/watch" {
            webView.evaluateJavaScript("window.__unreel ? window.__unreel.loadVideo('\(id)', \(startArg)) : 'missing'") { [weak self] result, _ in
                if (result as? String) == "missing" || result == nil { self?.navigate(id, start: start) }
            }
        } else {
            navigate(id, start: start)
        }
    }

    private func navigate(_ id: String, start: Double) {
        var comps = URLComponents(string: "https://m.youtube.com/watch")!
        comps.queryItems = [URLQueryItem(name: "v", value: id)] + (start > 1 ? [URLQueryItem(name: "t", value: "\(Int(start))s")] : [])
        pageReady = false
        state.pageLoading = true
        webView.load(URLRequest(url: comps.url!))
    }

    func stop() {
        webView.evaluateJavaScript("window.__unreel && window.__unreel.pause()")
        current = nil
        state.playing = false
        nowPlaying.clear()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func togglePlay() { js("toggle()") }
    func pause() { js("pause()") }
    func resume() { js("play()") }
    func seek(to t: Double) {
        state.time = t
        js("seekTo(\(max(0, t)))")
    }
    func seek(by delta: Double) { seek(to: min(max(0, state.time + delta), max(state.duration - 1, 0))) }
    func setRate(_ r: Double) { state.rate = r; js("setRate(\(r))") }
    func setQuality(_ q: String) { js("setQuality('\(q)')") }
    func togglePiP() {
        let script = """
        const v = document.querySelector('#movie_player video') || document.querySelector('video');
        if (!v) return 'no-video';
        v.removeAttribute('disablepictureinpicture'); v.disablePictureInPicture = false;
        if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return 'exited'; }
        try { await v.requestPictureInPicture(); return 'entered'; }
        catch (e) {
          if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
            v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
            return 'webkit:' + e.name + ':' + e.message;
          }
          return 'failed:' + e.name + ':' + e.message;
        }
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            self?.log.notice("PiP: \(String(describing: result), privacy: .public)")
            if case .success(let value) = result, let s = value as? String, s.hasPrefix("failed") {
                self?.onPiPUnavailable?()
            }
        }
    }

    func toggleCaptions(_ done: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript("window.__unreel ? window.__unreel.toggleCaptions() : false") { result, _ in
            done((result as? Bool) ?? false)
        }
    }

    func undoSkip() { js("undoSkip()") }

    private func js(_ call: String) {
        webView.evaluateJavaScript("window.__unreel && window.__unreel.\(call)")
    }

    private func updateNowPlaying() {
        guard let current else { return }
        nowPlaying.update(.init(videoId: current.id, title: current.title, author: current.channelName ?? "",
                                duration: state.duration, time: state.time, rate: state.rate, playing: state.playing))
    }

    private func handleRemote(_ command: NowPlayingController.Command) {
        switch command {
        case .play: resume()
        case .pause: pause()
        case .toggle: togglePlay()
        case .seekBy(let s): seek(by: s)
        case .seekTo(let t): seek(to: t)
        case .next: onEnded?()
        case .previous: seek(to: 0)
        }
    }

    // MARK: Lifecycle

    private var wasPlayingBeforeBackground = false

    func sceneWillResignActive() {
        wasPlayingBeforeBackground = state.playing
        if state.playing, settings.autoPiP, !state.pip { togglePiP() }
    }

    func sceneDidEnterBackground() {
        guard settings.backgroundPlay, wasPlayingBeforeBackground else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.state.playing else { return }
                self.resume()
            }
        }
    }

    // MARK: Page messages

    var onBlocked: ((Int) -> Void)?

    fileprivate func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "media":
            // Ignore stale reports from the previous video while a new one loads.
            if let id = body["videoId"] as? String, let current, id != current.id { return }
            let s = state
            s.playing = body["playing"] as? Bool ?? false
            s.time = body["time"] as? Double ?? s.time
            let d = body["duration"] as? Double ?? 0
            if d > 0 { s.duration = d }
            s.buffered = body["buffered"] as? Double ?? 0
            s.rate = body["rate"] as? Double ?? 1
            s.waiting = body["waiting"] as? Bool ?? false
            s.isAd = body["isAd"] as? Bool ?? false
            s.ended = body["ended"] as? Bool ?? false
            s.pip = body["pip"] as? Bool ?? false
            if let levels = body["levels"] as? [String], levels != s.levels { s.levels = levels }
            if let q = body["quality"] as? String, q != s.quality { s.quality = q }
            s.pageLoading = false
            if settings.keepScreenOn { UIApplication.shared.isIdleTimerDisabled = s.playing }
            if settings.lockScreenControls, !s.isAd { updateNowPlaying() }
        case "ended":
            if let id = body["videoId"] as? String, id == current?.id { onEnded?() }
        case "blocked":
            onBlocked?(body["count"] as? Int ?? 0)
        case "skipped":
            onSkippedSegment?(body["category"] as? String ?? "", body["seconds"] as? Int ?? 0)
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
}

// MARK: - Navigation

extension PlayerController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        guard action.targetFrame?.isMainFrame ?? false else { return decisionHandler(.allow) }
        let host = url.host?.lowercased() ?? ""
        let allowed = host.hasSuffix("youtube.com") || host.hasSuffix("google.com") || url.scheme == "about"
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        lastConfigJSON = (try? JSONSerialization.data(withJSONObject: pageConfig)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("Player process terminated; reloading")
        if let current { navigate(current.id, start: state.time) }
    }
}

// MARK: - Message proxy (avoids a retain cycle through WKUserContentController)

private final class MessageProxy: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    weak var player: PlayerController?
    init(_ player: PlayerController) { self.player = player }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { player?.handle(body) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any] else { replyHandler(nil, nil); return }
        MainActor.assumeIsolated {
            guard let player else { replyHandler(nil, nil); return }
            Task { @MainActor in replyHandler(await player.handleAsync(body), nil) }
        }
    }
}
