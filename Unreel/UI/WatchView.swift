import SwiftUI

struct WatchView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showComments = false
    @State private var showDescription = false
    @State private var dragOffset: CGFloat = 0

    private var landscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if landscape {
                playerArea(fullscreen: true)
                    .gesture(exitFullscreenGesture)
                    .statusBarHidden()
                    .persistentSystemOverlays(.hidden)
            } else {
                VStack(spacing: 0) {
                    Color.black
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { playerArea(fullscreen: false) }
                        .clipped()
                        .gesture(minimizeGesture)
                    details
                }
                .background(Color(uiColor: .systemBackground))
                .offset(y: dragOffset)
                .scaleEffect(1 - min(dragOffset / 3000, 0.08), anchor: .top)
            }
        }
        .background(Color.black.ignoresSafeArea(edges: landscape ? .all : .top).opacity(1 - min(dragOffset / 600, 1)))
        .onAppear { Orientation.shared.setPlayerVisible(true) }
        .onDisappear { Orientation.shared.setPlayerVisible(false) }
        .sheet(isPresented: $showComments) {
            if let token = app.watch?.commentsToken {
                CommentsView(token: token, count: app.watch?.commentsCount)
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

    /// Full screen: swipe down to leave.
    private var exitFullscreenGesture: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { g in
            if g.translation.height > 60, abs(g.translation.height) > abs(g.translation.width) { setOrientation(landscape: false) }
        }
    }

    /// Drag the player down to shrink the watch screen back into the mini player; swipe up for full screen.
    private var minimizeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { g in
                guard abs(g.translation.height) > abs(g.translation.width) else { return }
                dragOffset = max(0, g.translation.height)
            }
            .onEnded { g in
                if g.translation.height < -50, abs(g.translation.height) > abs(g.translation.width) {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                    setOrientation(landscape: true)
                } else if g.translation.height > 120 || g.predictedEndTranslation.height > 380 {
                    app.showPlayer = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dragOffset = 0 }
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    private func playerArea(fullscreen: Bool) -> some View {
        ZStack {
            Color.black.ignoresSafeArea(edges: fullscreen ? .all : [])
            PlayerSurface(player: app.player).ignoresSafeArea(edges: fullscreen ? .all : [])
            PlayerControls(state: app.player.state, player: app.player, fullscreen: fullscreen) {
                if fullscreen { setOrientation(landscape: false) } else { app.showPlayer = false }
            }
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
                        if !settings.hideRelated, !w.related.isEmpty { upNext(w) }
                    } else if let error = app.watchError {
                        ContentUnavailableView(error.contains("isn't available") ? "Video Unavailable" : "Couldn't Load Details",
                                           systemImage: "exclamationmark.triangle", description: Text(error))
                    }
                }
                .padding(.bottom, 40)
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
                        .font(.system(size: 19, weight: .bold))
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
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    SubscribeButton(subscribed: w.subscribed ?? false) { app.setSubscribed(c, !(w.subscribed ?? false)) }
                }
            }

            actionBar(w)

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
                    }
                    Divider().frame(height: 20)
                    Button { app.rate(.disliked) } label: {
                        Image(systemName: w.likeStatus == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .padding(.horizontal, 12)
                            .accessibilityLabel("Dislike")
                    }
                }
                .frame(height: 36)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentTransition(.symbolEffect(.replace))

                if let v = app.player.current {
                    ShareLink(item: v.shareURL) { Label("Share", systemImage: "arrowshape.turn.up.right").pill() }
                    let saved = app.watchLater.contains(v.id)
                    Button { app.toggleWatchLater(v) } label: {
                        Label(saved ? "Saved" : "Save", systemImage: saved ? "clock.fill" : "clock").pill()
                    }
                }
                Button { app.player.togglePiP() } label: { Label("PiP", systemImage: "pip.enter").pill() }
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
        .buttonStyle(.plain)
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
                Image(systemName: "list.bullet").foregroundStyle(.secondary)
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
                            .buttonStyle(.plain)
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
                Text("Up Next").font(.headline)
                Spacer()
                Toggle(isOn: $settings.autoplayNext) {
                    Text("Autoplay").font(.footnote).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
            }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(w.related) { v in
                    VideoRow(video: v).onAppear {
                        if v.id == w.related.last?.id { Task { await app.loadMoreRelated() } }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
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
            Text(subscribed ? "Subscribed" : "Subscribe")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(height: 36)
                .foregroundStyle(subscribed ? Color.primary : Color(uiColor: .systemBackground))
                .background(subscribed ? Color.secondary.opacity(0.18) : Color.primary, in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: subscribed)
    }
}

private extension View {
    func pill() -> some View {
        self.padding(.horizontal, 14)
            .frame(height: 36)
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
                            Text("Chapters").font(.headline)
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
                                        .buttonStyle(.plain)
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
        }
    }

    private func stat(_ value: String?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value ?? "–").font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(url: comment.avatar, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author).font(.caption.weight(.semibold))
                        .padding(.horizontal, comment.isOwner ? 6 : 0).padding(.vertical, comment.isOwner ? 1 : 0)
                        .background(comment.isOwner ? Color.secondary.opacity(0.2) : .clear, in: Capsule())
                    if let p = comment.published { Text(p).font(.caption).foregroundStyle(.secondary) }
                    if comment.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(linkified(comment.text)).font(.subheadline).textSelection(.enabled)
                if let l = comment.likes, !l.isEmpty {
                    Label(l, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Pages through comments (or replies) starting from a continuation token.
@MainActor
final class CommentsModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var next: String?
    private var started = false
    private let token: String

    init(token: String) { self.token = token }

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
    @StateObject private var model: CommentsModel

    init(token: String, count: String?) {
        self.token = token
        self.count = count
        _model = StateObject(wrappedValue: CommentsModel(token: token))
    }

    var body: some View {
        NavigationStack {
            CommentList(model: model)
                .navigationTitle(count.map { "Comments · \($0)" } ?? "Comments")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Comment.self) { parent in
                    RepliesView(parent: parent)
                }
        }
    }
}

private struct CommentList: View {
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
                    CommentCell(comment: c)
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
        _model = StateObject(wrappedValue: CommentsModel(token: parent.repliesToken ?? ""))
    }

    var body: some View {
        CommentList(model: model, header: parent)
            .navigationTitle("Replies")
            .navigationBarTitleDisplayMode(.inline)
    }
}
