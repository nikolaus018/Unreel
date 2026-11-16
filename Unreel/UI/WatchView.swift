import SwiftUI

struct WatchView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showComments = false
    @State private var showDescription = false
    @State private var dragOffset: CGFloat = 0
    @State private var passedDismissThreshold = false
    /// The details list is pulled down past its top far enough to minimize on release.
    @State private var pulledToMinimize = false

    private var landscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if landscape {
                playerArea(fullscreen: true)
                    .statusBarHidden()
                    .persistentSystemOverlays(.hidden)
                    // Only the bottom edge is deferred, so scrubbing near it doesn't leave the app.
                    // The top edge stays with iOS: swiping down there opens Notification / Control Center.
                    .defersSystemGestures(on: .bottom)
            } else {
                VStack(spacing: 0) {
                    Color.black
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { playerArea(fullscreen: false) }
                        .clipped()
                    details
                }
                .background(Color(uiColor: .systemBackground))
                .offset(y: dragOffset)
                .scaleEffect(1 - min(max(dragOffset, 0) / 3000, 0.08), anchor: .top)
            }
        }
        .background(Color.black.ignoresSafeArea(edges: landscape ? .all : .top).opacity(1 - min(max(dragOffset, 0) / 600, 1)))
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(toast: toast) { app.toast = nil }
                    .padding(.bottom, landscape ? 16 : 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { Orientation.shared.setPlayerVisible(true) }
        .onDisappear { Orientation.shared.setPlayerVisible(false) }
        .sheet(item: Binding(get: { app.showPlayer ? app.addToPlaylist : nil }, set: { app.addToPlaylist = $0 })) { video in
            AddToPlaylistSheet(video: video)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showComments) {
            if let token = app.watch?.commentsToken {
                CommentsView(token: token, count: app.watch?.commentsCount, videoId: app.watch?.videoId ?? "")
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showDescription) {
            if let w = app.watch {
                DescriptionSheet(details: w)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "unreel-seek", let t = Double(url.absoluteString.replacingOccurrences(of: "unreel-seek:", with: "")) {
                showDescription = false
                app.player.seek(to: t)
                return .handled
            }
            if let host = url.host?.lowercased(), host.contains("youtube.com") || host == "youtu.be" {
                showDescription = false
                app.open(url: url)
                return .handled
            }
            return .systemAction
        })
    }

    /// Portrait: drag the video down to shrink into the mini player, up for full screen.
    /// Full screen: swipe down to leave.
    private func verticalDragChanged(_ dy: CGFloat, fullscreen: Bool) {
        guard !fullscreen else { return }
        // Downward follows the finger; upward resists, hinting at full screen.
        dragOffset = dy >= 0 ? dy : -pow(-dy, 0.7)
        let passed = dy > 120
        if passed != passedDismissThreshold {
            passedDismissThreshold = passed
            app.haptic()
        }
    }

    private func verticalDragEnded(_ dy: CGFloat, predicted: CGFloat, fullscreen: Bool) {
        passedDismissThreshold = false
        if fullscreen {
            if dy > 60 || predicted > 200 { setOrientation(landscape: false) }
            return
        }
        if dy < -50 || predicted < -250 {
            withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
            setOrientation(landscape: true)
        } else if dy > 120 || predicted > 380 {
            app.showPlayer = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dragOffset = 0 }
        } else {
            withAnimation(.spring(duration: 0.35, bounce: 0.25)) { dragOffset = 0 }
        }
    }

    private func playerArea(fullscreen: Bool) -> some View {
        ZStack {
            Color.black.ignoresSafeArea(edges: fullscreen ? .all : [])
            ZoomableSurface(state: app.player.state, player: app.player, fullscreen: fullscreen)
                .ignoresSafeArea(edges: fullscreen ? .all : [])
            PlayerControls(state: app.player.state, player: app.player, fullscreen: fullscreen,
                           onCollapse: { if fullscreen { setOrientation(landscape: false) } else { app.showPlayer = false } },
                           onVerticalDrag: { verticalDragChanged($0, fullscreen: fullscreen) },
                           onVerticalDragEnd: { verticalDragEnded($0, predicted: $1, fullscreen: fullscreen) })
        }
    }

    // MARK: Details

    private var details: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    if let w = app.watch {
                        info(w)
                        if let q = app.queue { queueSection(q) }
                        if !settings.hideRelated, !relatedShown(w).isEmpty { upNext(w) }
                    } else if let error = app.watchError {
                        ContentUnavailableView(error.contains("isn't available") ? "Video Unavailable" : "Couldn't Load Details",
                                           systemImage: "exclamationmark.triangle", description: Text(error))
                    }
                }
                .padding(.bottom, 40)
            }
            // Pull the details down past the top and let go to minimize, like the video itself.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                let pulled = offset < -90
                if pulled != pulledToMinimize {
                    pulledToMinimize = pulled
                    if pulled { app.haptic() }
                }
            }
            .onScrollPhaseChange { old, phase in
                // Decide when the finger lifts, before the list bounces back.
                if old == .interacting, phase != .interacting, pulledToMinimize {
                    pulledToMinimize = false
                    app.showPlayer = false
                }
            }
            .onChange(of: app.watch?.videoId) { proxy.scrollTo("top") }
        }
    }

    private func info(_ w: WatchDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title and stats open the full description.
            Button { showDescription = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.title.isEmpty ? (app.player.current?.title ?? " ") : w.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text([w.views.map(shortViews), w.date].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        Text("…more").fontWeight(.semibold).foregroundStyle(.primary)
                    }
                    .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the description")
            .padding(.top, 14)

            if let c = w.channel {
                HStack(spacing: 10) {
                    Button { app.open(.channel(c.id)) } label: {
                        HStack(spacing: 10) {
                            Avatar(url: c.avatar, size: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                                if let s = c.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens the channel")
                    Spacer(minLength: 8)
                    SubscribeButton(subscribed: w.subscribed ?? false) { app.setSubscribed(c, !(w.subscribed ?? false)) }
                        // Until the real state arrives, show a neutral placeholder instead of a
                        // "Subscribe" that flips to "Subscribed".
                        .redacted(reason: w.isPlaceholder ? .placeholder : [])
                        .disabled(w.isPlaceholder)
                }
            }

            actionBar(w)
                .redacted(reason: w.isPlaceholder ? .placeholder : [])
                .disabled(w.isPlaceholder)

            if !settings.hideComments, w.commentsToken != nil { commentsCard(w) }
        }
        .padding(.horizontal, 16)
    }

    private func actionBar(_ w: WatchDetails) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Like / dislike pill.
                HStack(spacing: 0) {
                    Button { app.rate(.liked) } label: {
                        Label(w.likes ?? "Like", systemImage: w.likeStatus == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .padding(.leading, 14).padding(.trailing, 12)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Like")
                    .accessibilityValue(w.likes ?? "")
                    .accessibilityAddTraits(w.likeStatus == .liked ? .isSelected : [])
                    Divider().frame(height: 20)
                    Button { app.rate(.disliked) } label: {
                        Group {
                            if let d = w.dislikes, settings.returnDislike {
                                Label(d.formatted(.number.notation(.compactName)), systemImage: w.likeStatus == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            } else {
                                Image(systemName: w.likeStatus == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Dislike")
                    .accessibilityValue(w.dislikes.map { "\($0) dislikes" } ?? "")
                    .accessibilityAddTraits(w.likeStatus == .disliked ? .isSelected : [])
                }
                .frame(height: 40)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentTransition(.symbolEffect(.replace))

                if let v = app.player.current {
                    ShareLink(item: v.shareURL) { Label("Share", systemImage: "arrowshape.turn.up.right").pill() }
                    let saved = app.watchLater.contains(v.id)
                    Button { app.toggleWatchLater(v) } label: {
                        Label(saved ? "Saved" : "Watch Later", systemImage: saved ? "clock.fill" : "clock").pill()
                    }
                    Button { app.showAddToPlaylist(v) } label: {
                        Label("Save", systemImage: "text.badge.plus").pill()
                    }
                    .accessibilityLabel("Save to Playlist")
                }
                Button { app.player.togglePiP() } label: { Label("PiP", systemImage: "pip.enter").pill() }
                    .accessibilityLabel("Picture in Picture")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
        }
        .scrollClipDisabled()
    }

    private func commentsCard(_ w: WatchDetails) -> some View {
        Button { showComments = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Comments").font(.subheadline.weight(.semibold))
                    if let c = w.commentsCount { Text(c).font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                if let p = w.commentPreview {
                    Text(p).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows all comments")
    }

    /// The playlist being played, with the current video marked.
    private func queueSection(_ q: PlayQueue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.title).font(.headline).lineLimit(1)
                    Text("\(q.index + 1) of \(q.items.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "list.bullet").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(q.items.enumerated()), id: \.offset) { index, v in
                            Button { app.jump(to: index) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Thumbnail(video: v, cornerRadius: 10, small: true)
                                        .overlay {
                                            if index == q.index {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                                                Image(systemName: "waveform").font(.title2.weight(.bold)).foregroundStyle(.white).shadow(radius: 4)
                                            }
                                        }
                                    Text(v.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                }
                                .frame(width: 150)
                            }
                            .buttonStyle(.pressable)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(v.title)
                            .accessibilityValue(index == q.index ? "Now playing" : "\(index + 1) of \(q.items.count)")
                            .accessibilityAddTraits(index == q.index ? [.isButton, .isSelected] : .isButton)
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
                .onAppear { proxy.scrollTo(q.index, anchor: .center) }
                .onChange(of: q.index) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private func upNext(_ w: WatchDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Up Next").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Toggle(isOn: $settings.autoplayNext) {
                    Label("Autoplay", systemImage: settings.autoplayNext ? "play.circle.fill" : "play.slash")
                        .font(.footnote.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(settings.autoplayNext ? Color.accentColor : .secondary)
                .sensoryFeedback(.selection, trigger: settings.autoplayNext)
            }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(relatedShown(w)) { v in
                    VideoRow(video: v).onAppear {
                        if v.id == w.related.last?.id { Task { await app.loadMoreRelated() } }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    private func relatedShown(_ w: WatchDetails) -> [VideoItem] {
        w.related.filter { library.allows(.video($0), hideWatched: settings.hideWatched) }
    }

    private func shortViews(_ v: String) -> String {
        // "13,681,800 views" -> "13.7M views"
        let digits = v.filter(\.isNumber)
        guard let n = Double(digits), n >= 10_000 else { return v }
        return Int(n).formatted(.number.notation(.compactName)) + " views"
    }
}

// MARK: - Components

struct SubscribeButton: View {
    let subscribed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(subscribed ? "Subscribed" : "Subscribe", systemImage: subscribed ? "checkmark" : "plus")
                .labelStyle(SubscribeLabelStyle(showIcon: subscribed))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .foregroundStyle(subscribed ? Color.primary : Color(uiColor: .systemBackground))
                .background(subscribed ? Color.secondary.opacity(0.18) : Color.primary, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .animation(.snappy, value: subscribed)
        .accessibilityLabel(subscribed ? "Unsubscribe" : "Subscribe")
        .accessibilityValue(subscribed ? "Subscribed" : "")
    }
}

private struct SubscribeLabelStyle: LabelStyle {
    let showIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            if showIcon { configuration.icon.imageScale(.small).transition(.scale.combined(with: .opacity)) }
            configuration.title
        }
    }
}

private extension View {
    func pill() -> some View {
        self.padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}

struct DescriptionSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let details: WatchDetails

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(details.title).font(.title3.weight(.bold)).textSelection(.enabled)
                    HStack(spacing: 0) {
                        stat(details.likes, "Likes")
                        stat(details.views?.replacingOccurrences(of: " views", with: ""), "Views")
                        stat(details.date, "Published")
                    }
                    if !details.chapters.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Chapters").font(.headline).accessibilityAddTraits(.isHeader)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(details.chapters) { ch in
                                        Button {
                                            app.player.seek(to: ch.start)
                                            dismiss()
                                        } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                                                    .overlay { RemoteImage(url: ch.thumbnail) }
                                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                    .overlay(alignment: .bottomTrailing) {
                                                        Text(format(ch.start)).font(.caption2.weight(.semibold).monospacedDigit())
                                                            .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1)
                                                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                                                    }
                                                Text(ch.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                            }
                                            .frame(width: 140)
                                        }
                                        .buttonStyle(.pressable)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("\(ch.title), \(format(ch.start))")
                                        .accessibilityHint("Plays from this chapter")
                                        .accessibilityAddTraits(.isButton)
                                    }
                                }
                            }
                            .scrollClipDisabled()
                        }
                    }
                    if let d = details.description, !d.isEmpty {
                        Text(linkified(d, links: details.descriptionLinks)).font(.subheadline).textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                if let url = URL(string: "https://youtu.be/\(details.videoId)") {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url)
                    }
                }
            }
        }
    }

    private func stat(_ value: String?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value ?? "–").font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Makes links tappable: YouTube's own link targets first, then any other URL found in the text.
func linkified(_ text: String, links: [TextLink] = []) -> AttributedString {
    let ns = NSMutableAttributedString(string: text)
    let full = NSRange(location: 0, length: (text as NSString).length)
    var covered = IndexSet()
    for link in links {
        let range = NSRange(location: link.start, length: link.length)
        guard NSMaxRange(range) <= full.length else { continue }
        ns.addAttribute(.link, value: link.url, range: range)
        covered.insert(integersIn: range.location..<NSMaxRange(range))
    }
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        for match in detector.matches(in: text, range: full) where !covered.contains(match.range.location) {
            if let url = match.url { ns.addAttribute(.link, value: url, range: match.range) }
        }
    }
    return (try? AttributedString(ns, including: \.uiKit)) ?? AttributedString(text)
}

// MARK: - Comments

struct CommentCell: View {
    let comment: Comment
    /// Likes / un-likes; nil when not signed in.
    var onLike: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(url: comment.avatar, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author).font(.caption.weight(.semibold))
                        .padding(.horizontal, comment.isOwner ? 6 : 0).padding(.vertical, comment.isOwner ? 1 : 0)
                        .background(comment.isOwner ? Color.secondary.opacity(0.2) : .clear, in: Capsule())
                    if let p = comment.published { Text(p).font(.caption).foregroundStyle(.secondary) }
                    if comment.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                }
                Text(linkified(comment.text)).font(.subheadline).textSelection(.enabled)
                HStack(spacing: 18) {
                    if let onLike {
                        Button(action: onLike) {
                            Label(comment.likes?.isEmpty == false ? comment.likes! : "Like",
                                  systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .frame(minHeight: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(comment.isLiked ? Color.accentColor : .secondary)
                        .accessibilityLabel(comment.isLiked ? "Remove like" : "Like")
                        .accessibilityValue(comment.likes.map { "\($0) likes" } ?? "")
                    } else if let l = comment.likes, !l.isEmpty {
                        Label(l, systemImage: "hand.thumbsup").foregroundStyle(.secondary)
                            .accessibilityLabel("\(l) likes")
                    }
                }
                .font(.caption)
                .contentTransition(.symbolEffect(.replace))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: onLike == nil ? .combine : .contain)
    }
}

/// Pages through comments (or replies) starting from a continuation token.
@MainActor
final class CommentsModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// Parameters for posting at this level (a new comment, or a reply to `replyParams`).
    @Published private(set) var createParams: String?
    @Published private(set) var posting = false
    private var next: String?
    private var started = false
    private let token: String
    private let isReplies: Bool

    init(token: String, createParams: String? = nil, isReplies: Bool = false) {
        self.token = token
        self.createParams = createParams
        self.isReplies = isReplies
    }

    func toggleLike(_ c: Comment) async -> Bool {
        guard let i = comments.firstIndex(of: c), let token = c.isLiked ? c.unlikeAction : c.likeAction else { return false }
        let liked = !c.isLiked
        comments[i].isLiked = liked
        comments[i].likes = Self.adjust(c.likes, by: liked ? 1 : -1)
        do {
            try await InnerTube.shared.performCommentAction(token)
            return true
        } catch {
            if let j = comments.firstIndex(where: { $0.id == c.id }) { comments[j].isLiked = c.isLiked; comments[j].likes = c.likes }
            return false
        }
    }

    /// "12" -> "13"; compact counts like "1.2K" are left alone.
    private static func adjust(_ likes: String?, by delta: Int) -> String? {
        let n = Int(likes ?? "0") ?? -1
        guard n >= 0 else { return likes }
        let v = max(0, n + delta)
        return v == 0 ? nil : String(v)
    }

    /// Posts a comment (or reply) and shows it at the top. Returns false on failure.
    func post(_ text: String, author: Account?) async -> Bool {
        guard let params = createParams, !posting else { return false }
        posting = true
        defer { posting = false }
        do {
            let json = isReplies ? try await InnerTube.shared.createReply(text, params: params)
                                 : try await InnerTube.shared.createComment(text, params: params)
            let posted = Parser.comments(json).comments.first
                ?? Comment(id: UUID().uuidString, author: author?.handle ?? author?.name ?? "You", avatar: author?.avatar,
                           text: text, likes: nil, published: "Just now", replies: 0, isPinned: false, isOwner: false)
            comments.insert(posted, at: 0)
            return true
        } catch {
            return false
        }
    }

    func load() async {
        guard !loading else { return }
        let t = started ? next : token
        guard let t else { return }
        started = true
        loading = true
        defer { loading = false }
        do {
            let json = try await InnerTube.shared.continuation("next", token: t)
            let page = Parser.comments(json)
            if !isReplies, createParams == nil { createParams = Parser.createCommentParams(json) }
            let existing = Set(comments.map(\.id))
            comments += page.comments.filter { !existing.contains($0.id) }
            next = page.continuation == t ? nil : page.continuation
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CommentsView: View {
    let token: String
    let count: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CommentsModel

    init(token: String, count: String?, videoId: String) {
        self.token = token
        self.count = count
        // Fallback when the page doesn't include posting parameters.
        _model = StateObject(wrappedValue: CommentsModel(token: token, createParams: videoId.isEmpty ? nil : InnerTube.commentParams(videoId: videoId)))
    }

    var body: some View {
        NavigationStack {
            CommentList(model: model)
                .safeAreaInset(edge: .bottom) { CommentComposer(model: model, placeholder: "Add a comment…") }
                .navigationTitle(count.map { "Comments · \($0)" } ?? "Comments")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Comment.self) { parent in
                    RepliesView(parent: parent)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
    }
}

private struct CommentList: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: CommentsModel
    var header: Comment?

    var body: some View {
        List {
            if let header {
                CommentCell(comment: header)
                    .listRowBackground(Color.secondary.opacity(0.08))
            }
            ForEach(model.comments) { c in
                VStack(alignment: .leading, spacing: 6) {
                    CommentCell(comment: c, onLike: app.signedIn && (c.likeAction != nil || c.unlikeAction != nil) ? {
                        app.haptic()
                        Task {
                            if !(await model.toggleLike(c)) { app.show(Toast(icon: "exclamationmark.triangle", text: "Couldn't like the comment")) }
                        }
                    } : nil)
                    if c.replies > 0 || c.repliesToken != nil, c.repliesToken != nil, header == nil {
                        NavigationLink(value: c) {
                            Text(c.replies > 0 ? "\(c.replies) replies" : "View replies")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.leading, 46)
                    }
                }
                .onAppear { if c.id == model.comments.last?.id { Task { await model.load() } } }
            }
            if model.loading { HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden) }
            if let error = model.error, model.comments.isEmpty {
                ContentUnavailableView("Couldn't Load Comments", systemImage: "bubble.left", description: Text(error))
            }
        }
        .listStyle(.plain)
        .task { if model.comments.isEmpty { await model.load() } }
    }
}

private struct RepliesView: View {
    let parent: Comment
    @StateObject private var model: CommentsModel

    init(parent: Comment) {
        self.parent = parent
        _model = StateObject(wrappedValue: CommentsModel(token: parent.repliesToken ?? "", createParams: parent.replyParams, isReplies: true))
    }

    var body: some View {
        CommentList(model: model, header: parent)
            .safeAreaInset(edge: .bottom) { CommentComposer(model: model, placeholder: "Reply to \(parent.author)…") }
            .navigationTitle("Replies")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Text field at the bottom of the comments for posting (signed in only).
private struct CommentComposer: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: CommentsModel
    let placeholder: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if app.signedIn, model.createParams != nil {
            HStack(alignment: .bottom, spacing: 10) {
                Avatar(url: app.account?.avatar, size: 32)
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        Group {
                            if model.posting { ProgressView() } else { Image(systemName: "arrow.up").fontWeight(.bold) }
                        }
                        .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(model.posting)
                    .accessibilityLabel("Post")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: text.isEmpty)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            if await model.post(t, author: app.account) {
                text = ""
                focused = false
                app.successHaptic()
            } else {
                app.show(Toast(icon: "exclamationmark.triangle", text: "Couldn't post your comment"))
            }
        }
    }
}
