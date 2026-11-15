import SwiftUI
import WebKit

// MARK: - Video surface

/// Shows the player's web view (which renders only the video). Touches go to the native controls.
struct PlayerSurface: UIViewRepresentable {
    let player: PlayerController

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        player.attach(to: v)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {}

    func makeCoordinator() -> PlayerController { player }

    static func dismantleUIView(_ v: UIView, coordinator: PlayerController) {
        coordinator.detach(from: v)
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

    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var seekFeedback: (forward: Bool, id: Int)?
    @State private var feedbackCounter = 0
    @State private var seekStack = 0
    @State private var lastSeekTap: (forward: Bool, at: Date)?
    @GestureState private var boosting = false
    @State private var rateBeforeBoost: Double = 1

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
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geo.size.width * min(max(state.time / state.duration, 0), 1), height: 2.5)
                    }
                    .frame(height: 2.5)
                }
                .allowsHitTesting(false)
            }

            // Gesture layer: tap toggles controls, double tap on either side seeks.
            HStack(spacing: 0) {
                gestureZone(forward: false)
                gestureZone(forward: true)
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($boosting) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
            )

            if boosting {
                VStack {
                    Label("2×", systemImage: "forward.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, 14)
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
            }

            if let fb = seekFeedback {
                HStack {
                    if fb.forward { Spacer() }
                    VStack(spacing: 4) {
                        Image(systemName: fb.forward ? "forward.fill" : "backward.fill")
                            .font(.system(size: 26, weight: .semibold))
                        Text("\(seekStack) seconds").font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .frame(width: 110, height: 110)
                    .background(.black.opacity(0.35), in: Circle())
                    .padding(.horizontal, 40)
                    if !fb.forward { Spacer() }
                }
                .transition(.opacity)
                .id(fb.id)
                .allowsHitTesting(false)
            }

            if let reason = state.unplayable {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30))
                    Text("Video unavailable").font(.headline)
                    Text(reason).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8)).lineLimit(4)
                    Button("Close") { app.closePlayer() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
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
        .animation(.easeOut(duration: 0.25), value: seekFeedback?.id)
        .animation(.easeOut(duration: 0.15), value: boosting)
        .onChange(of: boosting) { _, on in
            if on {
                rateBeforeBoost = state.rate
                player.setRate(2)
                app.haptic()
                visible = false
            } else {
                player.setRate(rateBeforeBoost)
            }
        }
        .onAppear { scheduleHide() }
        .onChange(of: state.playing) { _, playing in if playing { scheduleHide() } else { show() } }
    }

    private func gestureZone(forward: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTapSeek(forward: forward) }
            .onTapGesture { visible.toggle(); if visible { scheduleHide() } }
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, fullscreen ? 28 : 12)
            .padding(.vertical, fullscreen ? 18 : 8)

            centerButtons
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onCollapse) {
                Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .glassEffect(.clear.interactive(), in: Circle())
            .accessibilityLabel(fullscreen ? "Exit full screen" : "Minimize player")

            if fullscreen, let title = player.current?.title {
                Text(title).font(.headline).lineLimit(1).shadow(radius: 4)
            }
            Spacer()

            Button { player.togglePiP() } label: {
                Image(systemName: state.pip ? "pip.exit" : "pip.enter").frame(width: 36, height: 36)
            }
            .glassEffect(.clear.interactive(), in: Circle())
            .accessibilityLabel("Picture in Picture")

            settingsMenu
        }
        .font(.system(size: 16, weight: .semibold))
    }

    private var settingsMenu: some View {
        Menu {
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                    Button { player.setRate(r); show() } label: {
                        if abs(state.rate - r) < 0.01 { Label(rateLabel(r), systemImage: "checkmark") } else { Text(rateLabel(r)) }
                    }
                }
            } label: { Label("Speed · \(rateLabel(state.rate))", systemImage: "gauge.with.dots.needle.50percent") }

            if !state.levels.isEmpty {
                Menu {
                    ForEach(state.levels, id: \.self) { q in
                        Button { player.setQuality(q) } label: {
                            if q == state.quality { Label(qualityLabel(q), systemImage: "checkmark") } else { Text(qualityLabel(q)) }
                        }
                    }
                } label: { Label("Quality · \(qualityLabel(state.quality))", systemImage: "sparkles.tv") }
            }

            Button {
                player.toggleCaptions { ok in
                    if !ok { app.show(Toast(icon: "captions.bubble", text: "No captions for this video")) }
                }
            } label: { Label("Captions", systemImage: "captions.bubble") }

            if let v = player.current {
                ShareLink(item: shareURL(v)) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 36, height: 36)
        }
        .glassEffect(.clear.interactive(), in: Circle())
        .onTapGesture { show() }
    }

    private var centerButtons: some View {
        HStack(spacing: fullscreen ? 64 : 44) {
            Button { player.seek(by: -10); show() } label: {
                Image(systemName: "gobackward.10").font(.system(size: 24, weight: .semibold)).frame(width: 52, height: 52)
            }
            .glassEffect(.clear.interactive(), in: Circle())

            Button {
                if state.ended { player.seek(to: 0); player.resume() } else { player.togglePlay() }
                show()
            } label: {
                Image(systemName: state.ended ? "arrow.counterclockwise" : (state.playing ? "pause.fill" : "play.fill"))
                    .font(.system(size: 34, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
            }
            .glassEffect(.clear.interactive(), in: Circle())
            .opacity((state.waiting && state.playing) || !state.hasStarted ? 0 : 1)

            Button { player.seek(by: 10); show() } label: {
                Image(systemName: "goforward.10").font(.system(size: 24, weight: .semibold)).frame(width: 52, height: 52)
            }
            .glassEffect(.clear.interactive(), in: Circle())
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text(format(scrubbing ?? state.time))
                Text("/").foregroundStyle(.white.opacity(0.6))
                Text(format(state.duration)).foregroundStyle(.white.opacity(0.8))
                if let ch = state.chapter(at: scrubbing ?? state.time) {
                    Text("· \(ch.title)").lineLimit(1).foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                Button {
                    setOrientation(landscape: !fullscreen)
                } label: {
                    Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(fullscreen ? "Exit full screen" : "Full screen")
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .shadow(radius: 3)
            Scrubber(time: state.time, duration: state.duration, buffered: state.buffered,
                     chapters: state.chapters.map(\.start), segments: state.segments, scrubbing: $scrubbing) { t in
                player.seek(to: t)
                scheduleHide()
            }
        }
    }

    // MARK: Helpers

    private func doubleTapSeek(forward: Bool) {
        // Repeated double taps in the same direction add up, like in YouTube.
        if let last = lastSeekTap, last.forward == forward, Date().timeIntervalSince(last.at) < 1.0 {
            seekStack += 10
        } else {
            seekStack = 10
        }
        lastSeekTap = (forward, Date())
        player.seek(by: forward ? 10 : -10)
        feedbackCounter += 1
        seekFeedback = (forward, feedbackCounter)
        let id = feedbackCounter
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { if seekFeedback?.id == id { seekFeedback = nil } }
        app.haptic()
    }

    private func show() {
        visible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled, state.playing, scrubbing == nil else { return }
            visible = false
        }
    }

    private func rateLabel(_ r: Double) -> String { r == 1 ? "Normal" : String(format: "%gx", r) }

    private func qualityLabel(_ q: String) -> String {
        VideoQuality(rawValue: q)?.title ?? (q == "auto" || q.isEmpty ? "Auto" : q)
    }

    private func shareURL(_ v: VideoItem) -> URL {
        state.time > 5 ? URL(string: "https://youtu.be/\(v.id)?t=\(Int(state.time))")! : v.shareURL
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
        .frame(height: 22)
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
                        }
                        .frame(width: 38, height: 38)
                        .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                    Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
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
                    RemoteImage(url: v.smallThumbnail)
                        .frame(width: 54, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.watch?.title.isEmpty == false ? app.watch!.title : v.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if placement != .inline, let c = app.watch?.channel?.name ?? v.channelName {
                        Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { player.togglePlay(); app.haptic() } label: {
                Image(systemName: state.playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(state.playing ? "Pause" : "Play")
            if placement != .inline {
                Button { app.haptic(); app.playNext() } label: {
                    Image(systemName: "forward.fill").frame(width: 32, height: 32)
                }
                .accessibilityLabel("Next video")
                .disabled(!app.canPlayNext)
                Button { app.closePlayer() } label: {
                    Image(systemName: "xmark").font(.body.weight(.bold)).frame(width: 28, height: 32)
                }
                .accessibilityLabel("Close player")
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { app.showPlayer = true }
        .contextMenu {
            Button { app.showPlayer = true } label: { Label("Open Player", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button { app.player.togglePiP() } label: { Label("Picture in Picture", systemImage: "pip.enter") }
            Button(role: .destructive) { app.closePlayer() } label: { Label("Close", systemImage: "xmark") }
        }
    }
}
