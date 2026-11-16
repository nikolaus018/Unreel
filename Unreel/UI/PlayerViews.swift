import SwiftUI
import WebKit

// MARK: - Video surface

/// Shows the player's web view (which renders only the video). Touches go to the native controls.
struct PlayerSurface: UIViewRepresentable {
    let player: PlayerController
    var role: PlayerController.SurfaceRole = .watch

    func makeUIView(context: Context) -> UIView {
        let v = role == .mini ? ScaledVideoHost() : UIView()
        v.backgroundColor = .black
        v.clipsToBounds = role == .mini
        v.isUserInteractionEnabled = false
        player.attach(to: v, role: role)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {}

    func makeCoordinator() -> PlayerController { player }

    static func dismantleUIView(_ v: UIView, coordinator: PlayerController) {
        coordinator.detach(from: v)
    }
}

/// The video surface, scaled up to fill the screen when zoomed (full screen only).
struct ZoomableSurface: View {
    @ObservedObject var state: PlaybackState
    let player: PlayerController
    let fullscreen: Bool

    var body: some View {
        GeometryReader { geo in
            PlayerSurface(player: player)
                .scaleEffect(fullscreen && state.zoomToFill ? fillScale(geo.size) : 1)
                .animation(.spring(duration: 0.35), value: state.zoomToFill)
        }
        .clipped()
    }

    /// How much a fitted picture must grow to cover the whole container.
    private func fillScale(_ size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        let a = CGFloat(state.videoAspect), container = size.width / size.height
        return a > container ? a / container : container / a
    }
}

/// Holds the player at a fixed size and scales it down to fill this view (the mini player), so the
/// page doesn't relayout and YouTube doesn't drop the quality for a tiny player.
final class ScaledVideoHost: UIView {
    private let base = CGSize(width: 384, height: 216)

    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews where sub.translatesAutoresizingMaskIntoConstraints {
            sub.transform = .identity
            sub.bounds = CGRect(origin: .zero, size: base)
            let scale = max(bounds.width / base.width, bounds.height / base.height)
            sub.transform = CGAffineTransform(scaleX: scale, y: scale)
            sub.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}

/// Keeps the web view in the window while no player screen shows it, so audio keeps playing.
struct ParkingHost: UIViewRepresentable {
    let player: PlayerController
    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        host.isUserInteractionEnabled = false
        host.clipsToBounds = true
        host.addSubview(player.parkingView)
        return host
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Controls

struct PlayerControls: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var state: PlaybackState
    let player: PlayerController
    var fullscreen: Bool
    var onCollapse: () -> Void
    /// Vertical drags on the video, handled by the watch screen (minimize, full screen).
    var onVerticalDrag: (CGFloat) -> Void = { _ in }
    var onVerticalDragEnd: (_ translation: CGFloat, _ predicted: CGFloat) -> Void = { _, _ in }

    private enum Zone { case back, center, forward }
    private enum Axis { case horizontal, vertical, ignored }

    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    /// Where the current scrub started, for the "+0:15" readout.
    @State private var scrubOrigin: Double = 0
    @State private var lastScrubChapter: Int?
    // Taps: a single tap toggles the controls; double taps seek, and further taps on the same
    // side keep seeking while "seek mode" lasts (like YouTube).
    @State private var lastTap: (zone: Zone, at: Date)?
    @State private var pendingTap: Task<Void, Never>?
    @State private var seekZone: Zone?
    @State private var seekAmount = 0
    @State private var seekModeUntil = Date.distantPast
    @State private var seekFeedbackID = 0
    @State private var flashIcon: (symbol: String, id: Int)?
    @State private var dragAxis: Axis?
    @State private var suppressTap = false
    @State private var notice: (text: String, icon: String, id: Int)?
    @State private var width: CGFloat = 1
    @State private var dragEndedAt = Date.distantPast
    /// True while a finger is down in a recognized drag; resets itself even if the drag is cancelled.
    @GestureState private var dragActive = false
    @GestureState private var boosting = false
    @State private var rateBeforeBoost: Double = 1
    @State private var showOptions = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Poster until the video actually starts, so there is never a black box.
            if !state.hasStarted, let v = player.current {
                Color.clear
                    .overlay { RemoteImage(url: v.thumbnail) }
                    .overlay(Color.black.opacity(0.25))
                    .clipped()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // Thin progress line while the controls are hidden (portrait only).
            if !visible && !fullscreen && state.duration > 0 && !state.isAd {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    VStack {
                        Spacer()
                        GeometryReader { geo in
                            Rectangle().fill(Color.accentColor)
                                .frame(width: geo.size.width * min(max(state.estimatedTime(at: context.date) / state.duration, 0), 1), height: 2.5)
                        }
                        .frame(height: 2.5)
                    }
                }
                .allowsHitTesting(false)
            }

            if state.captionTrack != nil, !state.cues.isEmpty, !state.isAd {
                CaptionOverlay(state: state, fullscreen: fullscreen, controlsVisible: visible && app.upNext == nil)
                    .allowsHitTesting(false)
            }

            // One surface for every gesture on the video.
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { handleTap(at: $0.location, width: geo.size.width) })
                    .simultaneousGesture(boostGesture)
                    .simultaneousGesture(zoomGesture, including: fullscreen ? .all : .subviews)
            }
            .accessibilityHidden(true)

            if let zone = seekZone, seekAmount > 0 {
                SeekRipple(forward: zone == .forward, seconds: seekAmount, reduceMotion: reduceMotion)
                    .id(seekZone == .forward ? 1 : 0)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if let flash = flashIcon {
                Image(systemName: flash.symbol)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(.black.opacity(0.35), in: Circle())
                    .id(flash.id)
                    .transition(reduceMotion ? .opacity : .scale(scale: 1.3).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if boosting || notice != nil {
                VStack {
                    Group {
                        if boosting {
                            Label("2× Speed", systemImage: "forward.fill")
                        } else if let notice {
                            Label(notice.text, systemImage: notice.icon)
                        }
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, fullscreen ? 20 : 12)
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
            }

            if let reason = state.unplayable {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title).accessibilityHidden(true)
                    Text("Video Unavailable").font(.headline)
                    Text(reason).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8)).lineLimit(4)
                    Button("Close Player") { app.closePlayer() }
                        .buttonStyle(.glass)
                        .padding(.top, 4)
                }
                .foregroundStyle(.white)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.75))
            } else if state.isAd {
                Label("Skipping ad…", systemImage: "forward.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .allowsHitTesting(false)
            } else if (state.waiting && state.playing) || !state.hasStarted {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                    .accessibilityLabel("Loading video")
            }

            if visible && !state.isAd && state.unplayable == nil && app.upNext == nil {
                controls.transition(.opacity)
            }

            if let up = app.upNext {
                UpNextCard(video: up.video, seconds: up.seconds, compact: !fullscreen)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: visible)
        .animation(.easeOut(duration: 0.3), value: state.hasStarted)
        .animation(.spring(duration: 0.3), value: app.upNext?.video.id)
        .animation(.easeOut(duration: 0.2), value: seekZone)
        .animation(.easeOut(duration: 0.25), value: flashIcon?.id)
        .animation(.easeOut(duration: 0.2), value: notice?.id)
        .animation(.easeOut(duration: 0.15), value: boosting)
        .animation(.easeOut(duration: 0.15), value: scrubbing == nil)
        .onChange(of: boosting) { _, on in
            if on {
                rateBeforeBoost = state.rate
                player.setRate(2)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                pendingTap?.cancel()
                suppressTap = true
                visible = false
            } else {
                player.setRate(rateBeforeBoost)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { suppressTap = false }
            }
        }
        .onChange(of: scrubbing == nil) { _, ended in
            if !ended { scrubOrigin = state.estimatedTime(); hideTask?.cancel() }
        }
        .onChange(of: fullscreen) { _, full in if !full { state.zoomToFill = false } }
        .onChange(of: dragActive) { _, active in
            // A drag the system cancelled never reaches onEnded: undo what it started.
            guard !active, let axis = dragAxis else { return }
            DispatchQueue.main.async {
                guard dragAxis == axis, !dragActive else { return }
                if axis == .horizontal { scrubbing = nil; scheduleHide() }
                if axis == .vertical { onVerticalDragEnd(0, 0) }
                dragAxis = nil
                dragEndedAt = Date()
            }
        }
        // On the whole player (not just the empty video), so drags that start on a button still work.
        .simultaneousGesture(dragGesture(width: width))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background { keyboardShortcuts }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { scheduleHide() }
        .onChange(of: state.playing) { _, playing in if playing { scheduleHide() } else { show() } }
        .onChange(of: voiceOver) { _, on in if on { show() } }
        .sheet(isPresented: $showOptions, onDismiss: { scheduleHide() }) {
            PlayerOptionsSheet(state: state, player: player)
                .presentationDetents(fullscreen ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Gestures

    /// Buttons ignore a touch that turned into a drag (released back over the button).
    private func guardTap(_ action: () -> Void) {
        guard !dragActive, Date().timeIntervalSince(dragEndedAt) > 0.3 else { return }
        action()
    }

    private func zone(at x: CGFloat, width: CGFloat) -> Zone {
        x < width * 0.35 ? .back : (x > width * 0.65 ? .forward : .center)
    }

    private func handleTap(at location: CGPoint, width: CGFloat) {
        if suppressTap { suppressTap = false; return }
        let z = zone(at: location.x, width: width)
        let now = Date()
        // Seek mode: every tap on the same side seeks again, no double tap needed.
        if z != .center, z == seekZone, now < seekModeUntil {
            seek(z)
            return
        }
        if let last = lastTap, last.zone == z, now.timeIntervalSince(last.at) < 0.3 {
            pendingTap?.cancel()
            lastTap = nil
            if z == .center {
                if state.ended { player.seek(to: 0); player.resume() } else { player.togglePlay() }
                flash(state.playing ? "pause.fill" : "play.fill")
                app.haptic()
            } else {
                seek(z)
            }
            return
        }
        lastTap = (z, now)
        pendingTap?.cancel()
        pendingTap = Task {
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            visible.toggle()
            if visible { scheduleHide() }
        }
    }

    private func seek(_ z: Zone) {
        if seekZone != z || Date() >= seekModeUntil { seekAmount = 0 }
        seekZone = z
        seekAmount += 10
        seekModeUntil = Date().addingTimeInterval(0.8)
        player.seek(by: z == .forward ? 10 : -10)
        app.haptic()
        if visible { scheduleHide() }
        seekFeedbackID += 1
        let id = seekFeedbackID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            guard seekFeedbackID == id else { return }
            seekZone = nil
            seekAmount = 0
        }
    }

    private func flash(_ symbol: String) {
        let id = (flashIcon?.id ?? 0) + 1
        flashIcon = (symbol, id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if flashIcon?.id == id { flashIcon = nil } }
    }

    private func showNotice(_ text: String, icon: String) {
        let id = (notice?.id ?? 0) + 1
        notice = (text, icon, id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if notice?.id == id { notice = nil } }
    }

    /// Horizontal: scrub (the whole width covers half the video, between 1 and 15 minutes).
    /// Vertical: handed to the watch screen.
    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { g in
                if dragAxis == nil {
                    pendingTap?.cancel()
                    // The scrubber's own drag already started (it sets `scrubbing` right away).
                    // In full screen, a swipe from the top edge belongs to iOS (Notification / Control Center).
                    let fromTopEdge = fullscreen && g.startLocation.y < 44
                    if fromTopEdge || boosting || scrubbing != nil || showOptions || state.unplayable != nil || app.upNext != nil {
                        dragAxis = .ignored
                    } else if abs(g.translation.width) > abs(g.translation.height) {
                        dragAxis = state.duration > 0 && !state.isAd ? .horizontal : .ignored
                        if dragAxis == .horizontal {
                            visible = true
                            scrubOrigin = state.estimatedTime()
                            lastScrubChapter = state.chapters.lastIndex { $0.start <= scrubOrigin }
                            scrubbing = scrubOrigin
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    } else {
                        dragAxis = .vertical
                    }
                }
                switch dragAxis {
                case .horizontal:
                    let span = min(max(state.duration * 0.5, 60), 900)
                    let t = min(max(scrubOrigin + Double(g.translation.width / max(width, 1)) * span, 0), state.duration)
                    scrubbing = t
                    let chapter = state.chapters.lastIndex { $0.start <= t }
                    if chapter != lastScrubChapter { lastScrubChapter = chapter; UISelectionFeedbackGenerator().selectionChanged() }
                case .vertical:
                    onVerticalDrag(g.translation.height)
                default:
                    break
                }
            }
            .onEnded { g in
                switch dragAxis {
                case .horizontal:
                    if let t = scrubbing { player.seek(to: t) }
                    scrubbing = nil
                    scheduleHide()
                case .vertical:
                    onVerticalDragEnd(g.translation.height, g.predictedEndTranslation.height)
                default:
                    break
                }
                dragAxis = nil
                dragEndedAt = Date()
            }
    }

    /// Press and hold anywhere for 2× until released.
    private var boostGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($boosting) { value, state, _ in
                if case .second(true, let drag) = value, (drag?.translation).map({ hypot($0.width, $0.height) < 30 }) ?? true {
                    state = true
                }
            }
    }

    /// Full screen: pinch out to fill the screen, pinch in to fit.
    private var zoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.04)
            .onEnded { value in
                if value.magnification > 1.08, !state.zoomToFill {
                    state.zoomToFill = true
                    app.haptic()
                    showNotice("Zoomed to Fill", icon: "arrow.up.left.and.arrow.down.right")
                } else if value.magnification < 0.92, state.zoomToFill {
                    state.zoomToFill = false
                    app.haptic()
                    showNotice("Original", icon: "arrow.down.right.and.arrow.up.left")
                }
            }
    }

    /// Hardware keyboard: space plays and pauses, arrows seek, F toggles full screen.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Play or Pause") { player.togglePlay(); show() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Back 10 Seconds") { player.seek(by: -10); show() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward 10 Seconds") { player.seek(by: 10); show() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button(fullscreen ? "Exit Full Screen" : "Full Screen") { setOrientation(landscape: !fullscreen) }
                .keyboardShortcut("f", modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        ZStack {
            // Edge to edge, also behind the Dynamic Island and home indicator.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.6), location: 0),
                .init(color: .black.opacity(0.15), location: 0.3),
                .init(color: .black.opacity(0.15), location: 0.65),
                .init(color: .black.opacity(0.7), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, fullscreen ? 20 : 12)
            .padding(.top, fullscreen ? 22 : 8)
            .padding(.bottom, fullscreen ? 14 : 4)

            if let t = scrubbing {
                scrubPreview(t)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            } else {
                centerButtons
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
    }

    /// Big time readout while scrubbing (from the bar or by swiping across the video).
    private func scrubPreview(_ t: Double) -> some View {
        let delta = Int((t - scrubOrigin).rounded())
        return VStack(spacing: 2) {
            Text(format(t))
                .font(.system(fullscreen ? .largeTitle : .title, design: .rounded, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
            Text((delta >= 0 ? "+" : "−") + format(Double(abs(delta))))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            if let ch = state.chapter(at: t) {
                Text(ch.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 280)
        .shadow(color: .black.opacity(0.3), radius: 8)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if !fullscreen {
                Button { guardTap(onCollapse) } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .glassEffect(.clear.interactive(), in: Circle())
                .accessibilityLabel("Minimize player")
            }
            if fullscreen, let title = player.current?.title, !title.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    if let c = player.current?.channelName { Text(c).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                }
                .shadow(color: .black.opacity(0.5), radius: 4)
            }
            Spacer(minLength: 8)

            topButton(state.captionTrack != nil ? "captions.bubble.fill" : "captions.bubble",
                      label: state.captionTrack != nil ? "Turn Off Captions" : "Turn On Captions") {
                if !player.toggleCaptions() { app.show(Toast(icon: "captions.bubble", text: "No captions for this video")) }
                show()
            }
            .opacity(state.captionTracks.isEmpty ? 0.45 : 1)

            topButton(state.pip ? "pip.exit" : "pip.enter", label: "Picture in Picture") {
                player.togglePiP()
            }

            topButton("gearshape", label: "Playback Options") {
                showOptions = true
                hideTask?.cancel()
            }
        }
    }

    private func topButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button { guardTap(action) } label: {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassEffect(.clear.interactive(), in: Circle())
        .accessibilityLabel(label)
    }

    private var centerButtons: some View {
        HStack(spacing: fullscreen ? 72 : 44) {
            Button { guardTap { player.seek(by: -10); show() } } label: {
                Image(systemName: "gobackward.10").font(.title2.weight(.semibold)).frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .glassEffect(.clear.interactive(), in: Circle())
            .accessibilityLabel("Back 10 seconds")

            Button {
                guardTap {
                    if state.ended { player.seek(to: 0); player.resume() } else { player.togglePlay() }
                    show()
                }
            } label: {
                Image(systemName: state.ended ? "arrow.counterclockwise" : (state.playing ? "pause.fill" : "play.fill"))
                    .font(.largeTitle.weight(.bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
                    .contentShape(Circle())
            }
            .glassEffect(.clear.interactive(), in: Circle())
            .opacity((state.waiting && state.playing) || !state.hasStarted ? 0 : 1)
            .accessibilityLabel(state.ended ? "Replay" : (state.playing ? "Pause" : "Play"))

            Button { guardTap { player.seek(by: 10); show() } } label: {
                Image(systemName: "goforward.10").font(.title2.weight(.semibold)).frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .glassEffect(.clear.interactive(), in: Circle())
            .accessibilityLabel("Forward 10 seconds")
        }
    }

    private var bottomBar: some View {
        // Interpolates between the page's reports so the time and scrubber move smoothly.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !state.playing || scrubbing != nil)) { context in
            bottomBarContent(now: state.estimatedTime(at: context.date))
        }
    }

    private func bottomBarContent(now: Double) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Group {
                    Text(format(scrubbing ?? now))
                    Text("/").foregroundStyle(.white.opacity(0.6))
                    Text(format(state.duration)).foregroundStyle(.white.opacity(0.8))
                }
                .accessibilityHidden(true)
                if let ch = state.chapter(at: scrubbing ?? now) {
                    Text("· \(ch.title)").lineLimit(1).foregroundStyle(.white.opacity(0.9))
                        .accessibilityLabel("Chapter: \(ch.title)")
                }
                Spacer(minLength: 8)
                if state.rate != 1 {
                    Text(rateLabel(state.rate)).font(.caption2.weight(.bold))
                        .accessibilityLabel("Speed \(rateLabel(state.rate))")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.2), in: Capsule())
                }
                Button {
                    guardTap { setOrientation(landscape: !fullscreen) }
                } label: {
                    Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.callout.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.vertical, -6)
                .accessibilityLabel(fullscreen ? "Exit Full Screen" : "Full Screen")
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .shadow(color: .black.opacity(0.5), radius: 3)
            Scrubber(time: now, duration: state.duration, buffered: state.buffered,
                     chapters: state.chapters.map(\.start), segments: state.segments, scrubbing: $scrubbing) { t in
                player.seek(to: t)
                scheduleHide()
            }
        }
    }

    // MARK: Helpers

    private func show() {
        visible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            // VoiceOver users can't tap the video to bring the controls back, so they stay.
            guard !Task.isCancelled, state.playing, scrubbing == nil, !showOptions, !voiceOver else { return }
            visible = false
        }
    }

    private func rateLabel(_ r: Double) -> String { r == 1 ? "Normal" : String(format: "%g×", r) }

    private func qualityLabel(_ q: String) -> String {
        VideoQuality(rawValue: q)?.title ?? (q == "auto" || q.isEmpty ? "Auto" : q)
    }

    private func shareURL(_ v: VideoItem) -> URL {
        state.time > 5 ? URL(string: "https://youtu.be/\(v.id)?t=\(Int(state.time))")! : v.shareURL
    }
}

/// Double-tap seek feedback: a soft arc on the tapped side with running arrows and the total.
struct SeekRipple: View {
    let forward: Bool
    let seconds: Int
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Ellipse()
                    .fill(.white.opacity(0.2))
                    .frame(width: w * 0.8, height: h * 1.7)
                    .offset(x: (forward ? 1 : -1) * w * 0.55)
                VStack(spacing: 6) {
                    arrows
                    Text("\(seconds) seconds")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4)
                .offset(x: (forward ? 1 : -1) * w * 0.3)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .animation(.snappy, value: seconds)
    }

    @ViewBuilder
    private var arrows: some View {
        if reduceMotion {
            row(highlight: nil)
        } else {
            PhaseAnimator([0, 1, 2]) { phase in
                row(highlight: phase)
            } animation: { _ in .easeInOut(duration: 0.18) }
        }
    }

    private func row(highlight: Int?) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                let index = forward ? i : 2 - i
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .scaleEffect(x: forward ? 1 : -1)
                    .opacity(highlight.map { $0 == index ? 1 : 0.35 } ?? 1)
            }
        }
    }
}

/// Captions drawn by the app, timed against the interpolated playback position.
struct CaptionOverlay: View {
    @ObservedObject var state: PlaybackState
    let fullscreen: Bool
    let controlsVisible: Bool
    @ScaledMetric(relativeTo: .body) private var fullSize: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var compactSize: CGFloat = 15

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            VStack {
                Spacer()
                if let text = CaptionParser.text(at: state.estimatedTime(at: context.date), in: state.cues) {
                    Text(text)
                        .font(.system(size: fullscreen ? fullSize : compactSize, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.horizontal, fullscreen ? 80 : 16)
                }
            }
            .padding(.bottom, controlsVisible && fullscreen ? 82 : (fullscreen ? 24 : 10))
            // The portrait player is too small for captions and controls at once.
            .opacity(controlsVisible && !fullscreen ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: controlsVisible)
        }
    }
}

/// Speed, quality and captions, in a sheet that works the same in portrait and full screen.
struct PlayerOptionsSheet: View {
    @ObservedObject var state: PlaybackState
    let player: PlayerController
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        NavigationStack {
            List {
                Section("Captions") {
                    row("Off", selected: state.captionTrack == nil) { player.setCaptions(nil) }
                    if state.captionTracks.isEmpty {
                        Text("This video has no captions").foregroundStyle(.secondary)
                    }
                    ForEach(state.captionTracks) { t in
                        row(t.name, selected: state.captionTrack == t) { player.setCaptions(t) }
                    }
                }
                Section("Speed") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(speeds, id: \.self) { r in
                                let selected = abs(state.rate - r) < 0.01
                                Button {
                                    player.setRate(r)
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    Text(r == 1 ? "1×" : String(format: "%g×", r))
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .frame(minWidth: 52, minHeight: 44)
                                        .foregroundStyle(selected ? Color.white : Color.primary)
                                        .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(r == 1 ? "Normal speed" : String(format: "%g times speed", r))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Quality") {
                    let levels = state.levels.filter { $0 != "auto" }
                    if levels.isEmpty {
                        Text("Available once the video is playing").foregroundStyle(.secondary)
                    } else {
                        ForEach(levels, id: \.self) { q in
                            row(qualityName(q), selected: q == state.quality) {
                                player.setQuality(q)
                            }
                        }
                    }
                }

            }
            .tint(.primary)
            .navigationTitle("Playback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
    }

    private func qualityName(_ q: String) -> String {
        if q == "tiny" { return "144p" }
        return VideoQuality(rawValue: q)?.title ?? q
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

func format(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

@MainActor
func setOrientation(landscape: Bool) {
    if landscape { Orientation.shared.enterFullscreen() } else { Orientation.shared.exitFullscreen() }
}

struct Scrubber: View {
    let time: Double
    let duration: Double
    let buffered: Double
    var chapters: [Double] = []
    var segments: [SponsorSegment] = []
    @Binding var scrubbing: Double?
    let onCommit: (Double) -> Void
    @State private var lastChapter: Int?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let current = scrubbing ?? time
            let p = duration > 0 ? min(max(current / duration, 0), 1) : 0
            let b = duration > 0 ? min(max(buffered / duration, 0), 1) : 0
            let h: CGFloat = scrubbing == nil ? 4 : 7
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(0.4)).frame(width: w * b)
                Capsule().fill(Color.accentColor).frame(width: w * p)
                // SponsorBlock segments
                if duration > 0 {
                    ForEach(segments, id: \.self) { seg in
                        Rectangle().fill(Color(red: 0, green: 0.83, blue: 0).opacity(0.9))
                            .frame(width: max(2, w * (seg.end - seg.start) / duration))
                            .offset(x: w * seg.start / duration)
                    }
                    // Chapter gaps
                    ForEach(chapters.dropFirst(), id: \.self) { start in
                        Rectangle().fill(.black.opacity(0.7)).frame(width: 2).offset(x: w * start / duration - 1)
                    }
                }
                Circle()
                    .fill(.white)
                    .frame(width: scrubbing == nil ? 12 : 18, height: scrubbing == nil ? 12 : 18)
                    .shadow(radius: 2)
                    .offset(x: w * p - (scrubbing == nil ? 6 : 9))
            }
            .frame(height: h)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard duration > 0 else { return }
                        let t = min(max(g.location.x / w, 0), 1) * duration
                        scrubbing = t
                        // A light tick when crossing into another chapter.
                        let idx = chapters.lastIndex { $0 <= t }
                        if idx != lastChapter { lastChapter = idx; UISelectionFeedbackGenerator().selectionChanged() }
                    }
                    .onEnded { _ in
                        if let s = scrubbing { onCommit(s) }
                        scrubbing = nil
                    }
            )
            .animation(.spring(duration: 0.2), value: scrubbing == nil)
        }
        // A 36 pt touch area that only takes 22 pt of layout.
        .frame(height: 36)
        .padding(.vertical, -7)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(duration > 0 ? "\(spoken(time)) of \(spoken(duration))" : "Not started")
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            switch direction {
            case .increment: onCommit(min(time + 10, duration))
            case .decrement: onCommit(max(time - 10, 0))
            @unknown default: break
            }
        }
    }

    private func spoken(_ t: Double) -> String {
        Duration.seconds(Int(t.isFinite ? t : 0)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// End-of-video card: "Up next in 5" with Cancel and Play Now.
struct UpNextCard: View {
    @EnvironmentObject private var app: AppModel
    let video: VideoItem
    let seconds: Int
    let compact: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            HStack(spacing: compact ? 12 : 18) {
                RemoteImage(url: video.smallThumbnail)
                    .frame(width: compact ? 120 : 200, height: compact ? 68 : 112)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        ZStack {
                            Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                            Circle().trim(from: 0, to: CGFloat(seconds) / 5)
                                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 1), value: seconds)
                            Text("\(seconds)").font(.headline.monospacedDigit())
                                .contentTransition(.numericText(countsDown: true))
                        }
                        .frame(width: 38, height: 38)
                        .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                    Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("Up next in \(seconds) seconds")
                    Text(video.title).font(compact ? .subheadline.weight(.semibold) : .headline).lineLimit(2).foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Button("Cancel") { app.cancelUpNext() }
                            .buttonStyle(.glass)
                        Button("Play Now") { app.playUpNextNow() }
                            .buttonStyle(.glassProminent)
                    }
                    .controlSize(compact ? .small : .regular)
                }
                Spacer(minLength: 0)
            }
            .padding(compact ? 14 : 40)
        }
    }
}

// MARK: - Mini player (tab bar accessory)

struct MiniPlayer: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var player: PlayerController
    @ObservedObject var state: PlaybackState
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 12) {
            if let v = player.current {
                if placement != .inline {
                    // The video itself keeps playing here; the thumbnail covers it until it starts.
                    ZStack {
                        PlayerSurface(player: player, role: .mini)
                        if !state.hasStarted { RemoteImage(url: v.smallThumbnail) }
                    }
                    .frame(width: 60, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.watch?.title.isEmpty == false ? app.watch!.title : v.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if placement != .inline, let c = app.watch?.channel?.name ?? v.channelName {
                        Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the player")
                .accessibilityAction { app.showPlayer = true }
            }
            Button { player.togglePlay(); app.haptic() } label: {
                Image(systemName: state.playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(state.playing ? "Pause" : "Play")
            if placement != .inline {
                Button { app.haptic(); app.playNext() } label: {
                    Image(systemName: "forward.fill").frame(width: 40, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Next video")
                .disabled(!app.canPlayNext)
                Button { app.closePlayer() } label: {
                    Image(systemName: "xmark").font(.body.weight(.bold)).frame(width: 36, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Close player")
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .onTapGesture { app.showPlayer = true }
        // Swipe up to open, swipe left for the next video.
        .gesture(
            DragGesture(minimumDistance: 16)
                .onEnded { g in
                    let dx = g.translation.width, dy = g.translation.height
                    if dy < -24, abs(dy) > abs(dx) {
                        app.showPlayer = true
                    } else if dx < -50, abs(dx) > abs(dy), app.canPlayNext {
                        app.haptic()
                        app.playNext()
                    }
                }
        )
        .accessibilityAction(named: "Next Video") { app.playNext() }
        .contextMenu {
            Button { app.showPlayer = true } label: { Label("Open Player", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button { app.player.togglePiP() } label: { Label("Picture in Picture", systemImage: "pip.enter") }
            Button(role: .destructive) { app.closePlayer() } label: { Label("Close", systemImage: "xmark") }
        }
    }
}
