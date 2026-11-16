import SwiftUI

// MARK: - Play action

/// Lets a screen decide what tapping a video does (a playlist plays it as part of a queue).
private struct PlayActionKey: EnvironmentKey {
    static let defaultValue: ((VideoItem) -> Void)? = nil
}

extension EnvironmentValues {
    var playAction: ((VideoItem) -> Void)? {
        get { self[PlayActionKey.self] }
        set { self[PlayActionKey.self] = newValue }
    }
}

// MARK: - Images

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: contentMode)
            default: Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
    }
}

struct Thumbnail: View {
    let video: VideoItem
    var cornerRadius: CGFloat = 14
    var small = false

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { RemoteImage(url: small ? video.smallThumbnail : video.thumbnail) }
            .overlay(alignment: .bottomLeading) {
                if let p = video.progress, p > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.35))
                            Rectangle().fill(Color.red).frame(width: geo.size.width * min(p, 1))
                        }
                    }
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if video.isLive {
                        Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.red, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else if let d = video.duration, !d.isEmpty {
                        Text(d)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .font((small ? Font.caption2 : Font.caption).weight(.semibold).monospacedDigit())
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(.white)
                .padding(small ? 4 : 7)
                .padding(.bottom, (video.progress ?? 0) > 0 ? 3 : 0)
            }
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        RemoteImage(url: url)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.06)))
            .accessibilityHidden(true)
    }
}

// MARK: - Button styles

/// Gives tappable cards the same pressed feedback as system buttons: a slight dim and shrink.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: - Video cells

extension VideoItem {
    /// What VoiceOver reads for a video cell.
    var accessibilityDescription: String {
        var parts = [title.isEmpty ? "Video" : title]
        if isLive { parts.append("Live") }
        if let channelName { parts.append(channelName) }
        if let views { parts.append(views) }
        if let published { parts.append(published) }
        if !isLive, let d = duration, let spoken = Self.spokenDuration(d) { parts.append(spoken) }
        if let p = progress, p > 0 { parts.append("\(Int(min(p, 1) * 100)) percent watched") }
        return parts.joined(separator: ", ")
    }

    /// "1:02:03" -> "1 hour, 2 minutes, 3 seconds"
    static func spokenDuration(_ text: String) -> String? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

struct VideoCard: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.playAction) private var playAction
    let video: VideoItem

    var body: some View {
        // Separate buttons, so the avatar can open the channel while the rest plays the video.
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) { Thumbnail(video: video) }
                .buttonStyle(.pressable)
            HStack(alignment: .top, spacing: 12) {
                if video.channelAvatar != nil {
                    Button {
                        if let id = video.channelId { app.open(.channel(id)) }
                    } label: {
                        Avatar(url: video.channelAvatar)
                    }
                    .buttonStyle(.pressable)
                    .disabled(video.channelId == nil)
                }
                Button(action: play) {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(video.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Text(video.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.pressable)
            }
            .padding(.horizontal, 4)
        }
        .videoAccessibility(video, play: play)
        .videoContextMenu(video)
    }

    private func play() {
        if let playAction { playAction(video) } else { app.play(video) }
    }
}

struct VideoRow: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.playAction) private var playAction
    @Environment(\.dynamicTypeSize) private var typeSize
    let video: VideoItem

    var body: some View {
        Button(action: play) {
            // At accessibility text sizes the thumbnail moves above the text so titles stay readable.
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                Thumbnail(video: video, cornerRadius: 10, small: !typeSize.isAccessibilitySize)
                    .frame(width: typeSize.isAccessibilitySize ? nil : 164)
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    if let c = video.channelName { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    let meta = [video.views, video.published].compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.pressable)
        .videoAccessibility(video, play: play)
        .videoContextMenu(video)
    }

    private func play() {
        if let playAction { playAction(video) } else { app.play(video) }
    }
}

struct ChannelRow: View {
    @EnvironmentObject private var app: AppModel
    let channel: ChannelItem

    var body: some View {
        Button { app.open(.channel(channel.id)) } label: {
            HStack(spacing: 14) {
                Avatar(url: channel.avatar, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
                    if let s = channel.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the channel")
        .contextMenu {
            Button { app.open(.channel(channel.id)) } label: { Label("Go to Channel", systemImage: "person.crop.square") }
            ShareLink(item: URL(string: "https://www.youtube.com/channel/\(channel.id)")!) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

struct PlaylistRow: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    let playlist: PlaylistItem

    var body: some View {
        Button { app.open(.playlist(playlist.id, playlist.title)) } label: {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { RemoteImage(url: playlist.thumbnail) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if let count = playlist.count, !count.isEmpty {
                            Label(count, systemImage: "list.bullet")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(4)
                        }
                    }
                    .frame(width: typeSize.isAccessibilitySize ? nil : 164)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text(playlist.owner ?? "Playlist").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([playlist.title, playlist.owner, playlist.count].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens the playlist")
        .accessibilityAddTraits(.isButton)
    }
}

private struct VideoAccessibility: ViewModifier {
    @EnvironmentObject private var app: AppModel
    let video: VideoItem
    var play: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityAction { if let play { play() } else { app.play(video) } }
            .accessibilityLabel(video.accessibilityDescription)
            .accessibilityHint("Plays the video")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Go to Channel") {
                if let id = video.channelId { app.open(.channel(id)) }
            }
            .accessibilityAction(named: app.watchLater.contains(video.id) ? "Remove from Watch Later" : "Save to Watch Later") {
                app.toggleWatchLater(video)
            }
    }
}

extension View {
    func videoAccessibility(_ video: VideoItem, play: (() -> Void)? = nil) -> some View {
        modifier(VideoAccessibility(video: video, play: play))
    }
}

extension View {
    func videoContextMenu(_ video: VideoItem) -> some View {
        modifier(VideoContextMenu(video: video))
    }
}

private struct VideoContextMenu: ViewModifier {
    @EnvironmentObject private var app: AppModel
    let video: VideoItem

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { app.play(video) } label: { Label("Play", systemImage: "play.fill") }
            if app.player.current != nil, app.player.current?.id != video.id {
                Button { app.enqueueNext(video) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            }
            if let id = video.channelId {
                Button { app.open(.channel(id)) } label: { Label("Go to Channel", systemImage: "person.crop.square") }
            }
            Button { app.toggleWatchLater(video) } label: {
                app.watchLater.contains(video.id)
                    ? Label("Remove from Watch Later", systemImage: "clock.fill")
                    : Label("Save to Watch Later", systemImage: "clock")
            }
            ShareLink(item: video.shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
            Button {
                UIPasteboard.general.url = video.shareURL
                app.show(Toast(icon: "link", text: "Link copied"))
            } label: { Label("Copy Link", systemImage: "link") }
        } preview: {
            VStack(alignment: .leading, spacing: 8) {
                Thumbnail(video: video, cornerRadius: 0)
                Text(video.title).font(.headline).lineLimit(2).padding(.horizontal, 12)
                Text(video.subtitle).font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 12)
            }
            .frame(width: 340)
        }
    }
}

// MARK: - Feed list

enum FeedStyle { case cards, rows }

struct FeedList<Header: View, Empty: View>: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: FeedModel
    var style: FeedStyle = .cards
    @ViewBuilder var header: () -> Header
    @ViewBuilder var empty: () -> Empty

    var body: some View {
        ScrollView {
            header()
            content
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
        .onChange(of: app.feedGeneration) { Task { await model.reload() } }
    }

    @ViewBuilder
    private var content: some View {
        if !model.loadedOnce || (model.isLoading && model.items.isEmpty) {
            SkeletonList(style: style)
        } else if let error = model.error, model.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }.buttonStyle(.glassProminent)
            }
            .padding(.top, 60)
        } else if model.items.isEmpty {
            empty().padding(.top, 40)
        } else {
            let columns = [GridItem(.adaptive(minimum: style == .cards ? 330 : 500), spacing: 18, alignment: .top)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: style == .cards ? 26 : 16) {
                ForEach(model.items) { item in
                    cell(item).onAppear { model.itemAppeared(item) }
                }
            }
            if model.isLoadingMore {
                ProgressView().padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: FeedItem) -> some View {
        switch item {
        case .video(let v):
            if style == .cards { VideoCard(video: v) } else { VideoRow(video: v) }
        case .channel(let c): ChannelRow(channel: c)
        case .playlist(let p): PlaylistRow(playlist: p)
        }
    }
}

extension FeedList where Header == EmptyView {
    init(model: FeedModel, style: FeedStyle = .cards, @ViewBuilder empty: @escaping () -> Empty) {
        self.init(model: model, style: style, header: { EmptyView() }, empty: empty)
    }
}

struct SkeletonList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let style: FeedStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style == .cards ? 26 : 16) {
            ForEach(0..<6, id: \.self) { _ in
                if style == .cards {
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).aspectRatio(16 / 9, contentMode: .fit)
                        HStack(alignment: .top, spacing: 12) {
                            Circle().frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 6) {
                                Capsule().frame(height: 12)
                                Capsule().frame(width: 160, height: 10)
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).frame(width: 164, height: 92)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().frame(height: 12)
                            Capsule().frame(width: 120, height: 10)
                        }
                    }
                }
            }
        }
        .foregroundStyle(Color.secondary.opacity(0.14))
        .phaseAnimator(reduceMotion ? [1.0] : [0.55, 1.0]) { view, phase in view.opacity(phase) } animation: { _ in .easeInOut(duration: 0.9) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                Divider().frame(height: 18)
                Button(title) { action(); dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 48)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.horizontal, 20)
        .offset(y: max(0, drag))
        .gesture(
            DragGesture(minimumDistance: 8)
                .updating($drag) { g, state, _ in state = g.translation.height }
                .onEnded { g in if g.translation.height > 24 || g.predictedEndTranslation.height > 80 { dismiss() } }
        )
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityAction(named: "Dismiss", dismiss)
        .onAppear {
            // Toasts are transient; make sure VoiceOver users hear them.
            AccessibilityNotification.Announcement(toast.text).post()
        }
    }
}
