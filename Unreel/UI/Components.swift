import SwiftUI

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
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
                .font(.system(size: small ? 10 : 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(small ? 4 : 7)
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
    }
}

// MARK: - Video cells

struct VideoCard: View {
    @EnvironmentObject private var app: AppModel
    let video: VideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Thumbnail(video: video)
            HStack(alignment: .top, spacing: 12) {
                if video.channelAvatar != nil {
                    Avatar(url: video.channelAvatar)
                        .onTapGesture { if let id = video.channelId { app.open(.channel(id)) } }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(video.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.play(video) }
        .videoContextMenu(video)
    }
}

struct VideoRow: View {
    @EnvironmentObject private var app: AppModel
    let video: VideoItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(video: video, cornerRadius: 10, small: true)
                .frame(width: 164)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                if let c = video.channelName { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                let meta = [video.views, video.published].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.play(video) }
        .videoContextMenu(video)
    }
}

struct ChannelRow: View {
    @EnvironmentObject private var app: AppModel
    let channel: ChannelItem

    var body: some View {
        HStack(spacing: 14) {
            Avatar(url: channel.avatar, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.headline).lineLimit(1)
                if let s = channel.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.open(.channel(channel.id)) }
    }
}

struct PlaylistRow: View {
    @EnvironmentObject private var app: AppModel
    let playlist: PlaylistItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: playlist.thumbnail) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Label(playlist.count ?? "", systemImage: "list.bullet")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }
                .frame(width: 164)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let o = playlist.owner { Text(o).font(.caption).foregroundStyle(.secondary) }
                Text("Playlist").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.open(.playlist(playlist.id, playlist.title)) }
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
        .phaseAnimator([0.55, 1.0]) { view, phase in view.opacity(phase) } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                Divider().frame(height: 18)
                Button(title) { action(); dismiss() }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 20)
        .onTapGesture(perform: dismiss)
    }
}
