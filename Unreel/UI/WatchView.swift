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
                    .ignoresSafeArea()
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
            if let host = url.host?.lowercased(), host.contains("youtube.com") || host == "youtu.be" {
                showDescription = false
                app.open(url: url)
                return .handled
            }
            return .systemAction
        })
    }

    /// Drag the player down to shrink the watch screen back into the mini player.
    private var minimizeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { g in
                guard abs(g.translation.height) > abs(g.translation.width) else { return }
                dragOffset = max(0, g.translation.height)
            }
            .onEnded { g in
                if g.translation.height > 120 || g.predictedEndTranslation.height > 380 {
                    app.showPlayer = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dragOffset = 0 }
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    private func playerArea(fullscreen: Bool) -> some View {
        ZStack {
            Color.black
            PlayerSurface(player: app.player)
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
                        if !settings.hideRelated, !w.related.isEmpty { upNext(w) }
                    } else if let error = app.watchError {
                        ContentUnavailableView("Couldn't Load Details", systemImage: "exclamationmark.triangle", description: Text(error))
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
                    if let d = details.description, !d.isEmpty {
                        Text(linkified(d)).font(.subheadline).textSelection(.enabled)
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

func linkified(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
    let ns = text as NSString
    for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard let url = match.url, let range = Range(match.range, in: text),
              let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
        attributed[lower..<upper].link = url
        attributed[lower..<upper].foregroundColor = .accentColor
    }
    return attributed
}

// MARK: - Comments

struct CommentsView: View {
    let token: String
    let count: String?
    @State private var comments: [Comment] = []
    @State private var next: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(comments) { c in
                    HStack(alignment: .top, spacing: 12) {
                        Avatar(url: c.avatar, size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(c.author).font(.caption.weight(.semibold))
                                    .padding(.horizontal, c.isOwner ? 6 : 0).padding(.vertical, c.isOwner ? 1 : 0)
                                    .background(c.isOwner ? Color.secondary.opacity(0.2) : .clear, in: Capsule())
                                if let p = c.published { Text(p).font(.caption).foregroundStyle(.secondary) }
                                if c.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text(linkified(c.text)).font(.subheadline).textSelection(.enabled)
                            HStack(spacing: 14) {
                                if let l = c.likes, !l.isEmpty { Label(l, systemImage: "hand.thumbsup") }
                                if c.replies > 0 { Label("\(c.replies) replies", systemImage: "bubble.left") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .onAppear { if c.id == comments.last?.id { Task { await load() } } }
                }
                if loading { HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden) }
                if let error, comments.isEmpty {
                    ContentUnavailableView("Couldn't Load Comments", systemImage: "bubble.left", description: Text(error))
                }
            }
            .listStyle(.plain)
            .navigationTitle(count.map { "Comments · \($0)" } ?? "Comments")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        let t = comments.isEmpty ? token : next
        guard let t else { return }
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
