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

    func updateUIView(_ v: UIView, context: Context) { player.attach(to: v) }

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

    var body: some View {
        ZStack {
            // Gesture layer: tap toggles controls, double tap on either side seeks.
            HStack(spacing: 0) {
                gestureZone(forward: false)
                gestureZone(forward: true)
            }

            if let fb = seekFeedback {
                HStack {
                    if fb.forward { Spacer() }
                    Label(fb.forward ? "10s" : "10s", systemImage: fb.forward ? "goforward.10" : "gobackward.10")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(22)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(.horizontal, 50)
                    if !fb.forward { Spacer() }
                }
                .transition(.opacity)
                .id(fb.id)
                .allowsHitTesting(false)
            }

            if state.isAd {
                Label("Skipping ad…", systemImage: "forward.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .allowsHitTesting(false)
            } else if state.waiting && state.playing || (state.pageLoading && state.time == 0) {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }

            if visible && !state.isAd {
                controls.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: visible)
        .animation(.easeOut(duration: 0.25), value: seekFeedback?.id)
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
            .opacity(state.waiting && state.playing ? 0 : 1)

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
            Scrubber(time: state.time, duration: state.duration, buffered: state.buffered, scrubbing: $scrubbing) { t in
                player.seek(to: t)
                scheduleHide()
            }
        }
    }

    // MARK: Helpers

    private func doubleTapSeek(forward: Bool) {
        player.seek(by: forward ? 10 : -10)
        feedbackCounter += 1
        seekFeedback = (forward, feedbackCounter)
        let id = feedbackCounter
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if seekFeedback?.id == id { seekFeedback = nil } }
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

func setOrientation(landscape: Bool) {
    guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
    scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
}

struct Scrubber: View {
    let time: Double
    let duration: Double
    let buffered: Double
    @Binding var scrubbing: Double?
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let current = scrubbing ?? time
            let p = duration > 0 ? min(max(current / duration, 0), 1) : 0
            let b = duration > 0 ? min(max(buffered / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(0.4)).frame(width: w * b)
                Capsule().fill(Color.accentColor).frame(width: w * p)
                Circle()
                    .fill(.white)
                    .frame(width: scrubbing == nil ? 12 : 18, height: scrubbing == nil ? 12 : 18)
                    .shadow(radius: 2)
                    .offset(x: w * p - (scrubbing == nil ? 6 : 9))
            }
            .frame(height: scrubbing == nil ? 4 : 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard duration > 0 else { return }
                        scrubbing = min(max(g.location.x / w, 0), 1) * duration
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
                Button { app.playNext() } label: {
                    Image(systemName: "forward.fill").frame(width: 32, height: 32)
                }
                .accessibilityLabel("Next video")
                .disabled(app.watch?.related.isEmpty ?? true)
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { app.showPlayer = true }
    }
}
