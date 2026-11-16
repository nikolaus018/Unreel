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
    /// False until the current video has actually started (the poster shows until then).
    @Published var hasStarted = false
    /// Why YouTube won't play the current video (private, age-restricted, blocked…).
    @Published var unplayable: String?
    @Published var segments: [SponsorSegment] = []
    @Published var chapters: [Chapter] = []
    @Published var captionTracks: [CaptionTrack] = []
    @Published var captionTrack: CaptionTrack?
    @Published var cues: [CaptionCue] = []
    /// Width / height of the video picture (for zoom to fill).
    @Published var videoAspect: Double = 16 / 9
    /// Full screen: the picture fills the screen (cropped) instead of fitting.
    @Published var zoomToFill = false
    /// When `time` was last reported, to interpolate between reports.
    var timeStamp = Date()

    /// Playback time estimated between the page's reports (smooth captions and scrubber).
    func estimatedTime(at now: Date = Date()) -> Double {
        guard playing, !waiting else { return time }
        return min(time + now.timeIntervalSince(timeStamp) * rate, duration > 0 ? duration : .infinity)
    }

    func chapter(at t: Double) -> Chapter? { chapters.last { $0.start <= t } }
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
    /// Lock screen / headphone "next" and "previous".
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// A seek the page hasn't reported back yet; older time reports are ignored until it lands.
    private var pendingSeek: (time: Double, at: Date)?
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
    /// Caption files received for the current video, keyed "lang|kind".
    private var captionFiles: [String: String] = [:]
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

    /// Where a video surface sits: the watch screen, or the mini player above the tab bar.
    enum SurfaceRole { case watch, mini }

    /// Video surfaces currently in the view hierarchy, newest last.
    private var surfaces: [(view: UIView, role: SurfaceRole)] = []

    /// Whether the watch screen is (or is about to be) shown. Set as soon as it opens or closes,
    /// so the video moves before the screen animates away and never leaves the window (which
    /// makes WebKit pause it for a moment).
    var watchVisible = false {
        didSet { if watchVisible != oldValue { placeBest() } }
    }

    /// Registers a surface and moves the video to the best one.
    func attach(to container: UIView, role: SurfaceRole) {
        surfaces.removeAll { $0.view === container }
        surfaces.append((container, role))
        placeBest()
    }

    /// Unregisters a surface; the video moves to the next best surface, or back to parking.
    func detach(from container: UIView) {
        surfaces.removeAll { $0.view === container }
        if webView.superview === container { placeBest() }
    }

    /// The watch screen when it's open, otherwise the mini player; if the preferred one isn't
    /// there yet, the video stays on the surface it's on.
    private func placeBest() {
        let preferred: SurfaceRole = watchVisible ? .watch : .mini
        if let target = surfaces.last(where: { $0.role == preferred }) {
            place(in: target.view, scaled: target.role == .mini)
        } else if let current = surfaces.first(where: { $0.view === webView.superview }) {
            place(in: current.view, scaled: current.role == .mini)
        } else if let any = surfaces.last {
            place(in: any.view, scaled: any.role == .mini)
        } else {
            park()
        }
    }

    private func place(in container: UIView, scaled: Bool) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.transform = .identity
        container.addSubview(webView)
        if scaled {
            // The mini player shows a scaled-down copy, so the page keeps its size (and quality).
            webView.translatesAutoresizingMaskIntoConstraints = true
            container.setNeedsLayout()
            container.layoutIfNeeded()
        } else {
            webView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
    }

    private func park() {
        guard webView.superview !== parking else { return }
        webView.removeFromSuperview()
        webView.transform = .identity
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
        state.hasStarted = false
        state.unplayable = nil
        state.segments = []
        state.chapters = []
        state.captionTracks = []
        state.captionTrack = nil
        state.cues = []
        captionFiles = [:]
        state.time = start
        state.duration = 0
        state.buffered = 0
        state.ended = false
        state.waiting = true
        state.isAd = false
        state.videoAspect = 16 / 9
        pendingSeek = nil
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

    /// Fills in the title/channel once the watch page details arrive (links open with only an ID).
    func updateMetadata(title: String, channel: String?) {
        guard var c = current else { return }
        if c.title.isEmpty || c.title != title { c.title = title }
        if c.channelName == nil { c.channelName = channel }
        current = c
        updateNowPlaying()
    }

    /// Loads the mobile site once in the background so the first video starts faster.
    func prewarm() {
        guard current == nil, webView.url == nil else { return }
        webView.load(URLRequest(url: URL(string: "https://m.youtube.com/")!))
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
        let target = max(0, t)
        state.time = target
        state.timeStamp = Date()
        state.ended = false
        pendingSeek = (target, Date())
        js("seekTo(\(target))")
    }
    /// Relative seek from the interpolated position. Before the duration is known only the lower bound applies.
    func seek(by delta: Double) {
        let upper = state.duration > 0 ? max(state.duration - 1, 0) : .infinity
        seek(to: min(max(0, state.estimatedTime() + delta), upper))
    }
    func setRate(_ r: Double) {
        state.rate = r
        log.notice("rate -> \(r)")
        js("setRate(\(r))")
    }
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

    /// Leaves Picture in Picture if it is on (no-op otherwise).
    func exitPiP() {
        webView.callAsyncJavaScript("""
        const v = document.querySelector('#movie_player video') || document.querySelector('video');
        if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return 'exited'; }
        if (v && v.webkitPresentationMode === 'picture-in-picture') { v.webkitSetPresentationMode('inline'); return 'inline'; }
        return 'none';
        """, arguments: [:], in: nil, in: .page) { _ in }
    }

    // MARK: Captions

    /// Reads the video's caption tracks and turns on the preferred language, if there is one.
    private func loadCaptionTracks() {
        webView.evaluateJavaScript("window.__unreel ? JSON.stringify(window.__unreel.captionTracks()) : '[]'") { [weak self] result, _ in
            guard let self, let json = result as? String, let data = json.data(using: .utf8),
                  let tracks = try? JSONDecoder().decode([CaptionTrack].self, from: data) else { return }
            self.state.captionTracks = tracks
            self.log.notice("caption tracks: \(tracks.map(\.id).joined(separator: ","), privacy: .public)")
            if let lang = self.settings.captionsLanguage, self.state.captionTrack == nil,
               let track = Self.bestTrack(for: lang, in: tracks) {
                self.setCaptions(track, remember: false)
            }
        }
    }

    /// The player's own track list is only filled once captions are loaded; re-read it then.
    private func refreshCaptionTracks() {
        webView.evaluateJavaScript("window.__unreel ? JSON.stringify(window.__unreel.captionTracks()) : '[]'") { [weak self] result, _ in
            guard let self, let json = result as? String, let data = json.data(using: .utf8),
                  let tracks = try? JSONDecoder().decode([CaptionTrack].self, from: data), !tracks.isEmpty else { return }
            if tracks != self.state.captionTracks { self.state.captionTracks = tracks }
        }
    }

    static func bestTrack(for lang: String, in tracks: [CaptionTrack]) -> CaptionTrack? {
        tracks.first { $0.lang == lang && !$0.isAuto }
            ?? tracks.first { $0.lang.hasPrefix(lang) && !$0.isAuto }
            ?? tracks.first { $0.lang == lang }
            ?? tracks.first { $0.lang.hasPrefix(lang) }
    }

    func setCaptions(_ track: CaptionTrack?, remember: Bool = true) {
        state.captionTrack = track
        state.cues = []
        if remember { settings.captionsLanguage = track?.lang }
        log.notice("setCaptions \(track?.id ?? "off", privacy: .public)")
        if let track {
            if let file = captionFiles[track.id] { state.cues = CaptionParser.json3(file) }
            js("setCaptions('\(track.lang)', '\(track.kind)')")
            ensureCaptionsLoaded(track, attempt: 1)
        } else {
            js("captionsOff()")
        }
    }

    /// If the player hasn't downloaded the track yet, turn captions off and on in the page,
    /// which reliably makes it fetch them.
    private func ensureCaptionsLoaded(_ track: CaptionTrack, attempt: Int) {
        let videoId = current?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.current?.id == videoId, self.state.captionTrack == track,
                  self.captionFiles[track.id] == nil, attempt <= 3 else { return }
            self.log.notice("captions not loaded, retrying (\(attempt))")
            self.js("captionsOff()")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard self.state.captionTrack == track else { return }
                self.js("setCaptions('\(track.lang)', '\(track.kind)')")
                self.ensureCaptionsLoaded(track, attempt: attempt + 1)
            }
        }
    }

    /// The CC button: off if on; otherwise the remembered language, the device language, or the first track.
    func toggleCaptions() -> Bool {
        if state.captionTrack != nil { setCaptions(nil); return true }
        let tracks = state.captionTracks
        guard !tracks.isEmpty else { return false }
        let device = Locale.current.language.languageCode?.identifier ?? "en"
        let track = settings.captionsLanguage.flatMap { Self.bestTrack(for: $0, in: tracks) }
            ?? Self.bestTrack(for: device, in: tracks)
            ?? Self.bestTrack(for: "en", in: tracks)
            ?? tracks.first
        setCaptions(track)
        return true
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
        if !isActive {
            switch command {
            case .pause: remotePausedWhileInactive = true
            case .toggle: remotePausedWhileInactive = state.playing
            case .play: remotePausedWhileInactive = false
            default: break
            }
        }
        switch command {
        case .play: resume()
        case .pause: pause()
        case .toggle: togglePlay()
        case .seekBy(let s): seek(by: s)
        case .seekTo(let t): seek(to: t)
        case .next: onNext?()
        case .previous: onPrevious?()
        }
    }

    // MARK: Lifecycle

    private var wasPlayingBeforeBackground = false
    /// The user paused from the lock screen / Notification Center while the app wasn't active.
    private var remotePausedWhileInactive = false
    private var isActive = true
    private var enteredBackground = false
    /// PiP the app started on its own when the scene went inactive.
    private var autoStartedPiP = false

    /// Inactive also happens for Notification Center, Control Center and the app switcher.
    /// Automatic PiP has to start now (iOS won't start it once the app is in the background);
    /// if the app turns out not to leave, `sceneDidBecomeActive` undoes it.
    func sceneWillResignActive() {
        isActive = false
        enteredBackground = false
        wasPlayingBeforeBackground = state.playing
        remotePausedWhileInactive = false
        autoStartedPiP = false
        if state.playing, settings.autoPiP, !state.pip {
            autoStartedPiP = true
            togglePiP()
        }
    }

    /// Back from Notification Center, Control Center or a peek at the app switcher (the app never
    /// left the screen): if something paused the video meanwhile (not the user), carry on.
    func sceneDidBecomeActive() {
        isActive = true
        defer { wasPlayingBeforeBackground = false; remotePausedWhileInactive = false; enteredBackground = false; autoStartedPiP = false }
        guard wasPlayingBeforeBackground, !enteredBackground, current != nil else { return }
        // Notification / Control Center: back to inline, as if nothing happened.
        if autoStartedPiP { exitPiP() }
        guard !remotePausedWhileInactive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.current != nil, !self.state.playing, !self.state.ended else { return }
            self.resume()
        }
    }

    func sceneDidEnterBackground() {
        enteredBackground = true
        guard settings.backgroundPlay, wasPlayingBeforeBackground, !remotePausedWhileInactive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.state.playing, !self.remotePausedWhileInactive else { return }
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
            let reported = body["time"] as? Double ?? s.time
            if let p = pendingSeek, abs(reported - p.time) > 2, Date().timeIntervalSince(p.at) < 1.5 {
                // A report from before the seek landed: keep showing the target.
            } else {
                pendingSeek = nil
                s.time = reported
                s.timeStamp = Date()
            }
            if let w = body["vw"] as? Double, let h = body["vh"] as? Double, w > 0, h > 0, abs(w / h - s.videoAspect) > 0.01 {
                s.videoAspect = w / h
            }
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
            if s.playing && s.time > 0.05 && !s.isAd && !s.hasStarted {
                s.hasStarted = true
                loadCaptionTracks()
            }
            if settings.keepScreenOn { UIApplication.shared.isIdleTimerDisabled = s.playing }
            if settings.lockScreenControls, !s.isAd { updateNowPlaying() }
        case "captions":
            guard let lang = body["lang"] as? String, let text = body["body"] as? String else { return }
            if let id = body["videoId"] as? String, let current, id != current.id { return }
            let kind = body["kind"] as? String ?? ""
            // Keep every file: YouTube may download a track before the app asks for it.
            captionFiles[lang + "|" + kind] = text
            refreshCaptionTracks()
            log.notice("captions file \(lang, privacy: .public)|\(kind, privacy: .public) bytes=\(text.count)")
            if let track = state.captionTrack, track.lang == lang, track.kind == kind {
                state.cues = CaptionParser.json3(text)
            }
        case "unplayable":
            // Error responses often have no videoDetails; a report without an ID is about the current video.
            let id = body["videoId"] as? String
            if id == nil || id == current?.id {
                state.unplayable = (body["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "This video can't be played."
            }
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
        if id == current?.id { state.segments = segments.map { SponsorSegment(start: $0.start, end: $0.end, category: $0.category) } }
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
