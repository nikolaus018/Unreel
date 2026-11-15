import SwiftUI

struct WatchView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showComments = false
    @State private var descriptionExpanded = false

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
                    playerArea(fullscreen: false)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(.black)
                    details
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
        .background(Color.black.ignoresSafeArea(edges: landscape ? .all : .top))
        .sheet(isPresented: $showComments) {
            if let token = app.watch?.commentsToken {
                CommentsView(token: token, count: app.watch?.commentsCount)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let host = url.host?.lowercased(), host.contains("youtube.com") || host == "youtu.be" {
                app.open(url: url)
                return .handled
            }
            return .systemAction
        })
    }

    private func playerArea(fullscreen: Bool) -> some View {
        ZStack {
            Color.black
            PlayerSurface(player: app.player)
            PlayerControls(state: app.player.state, player: app.player, fullscreen: fullscreen) {
                if fullscreen { setOrientation(landscape: false) } else { app.showPlayer = false }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { g in
                if !fullscreen, g.translation.height > 90, abs(g.translation.width) < 80 { app.showPlayer = false }
            }
        )
    }

    // MARK: Details

    private var details: some View {
        ScrollView {
            if let w = app.watch {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(w.title.isEmpty ? (app.player.current?.title ?? "") : w.title)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        let meta = [w.views, w.date].compactMap { $0 }.joined(separator: " · ")
                        if !meta.isEmpty { Text(meta).font(.subheadline).foregroundStyle(.secondary) }
                    }

                    if let c = w.channel {
                        Button { app.open(.channel(c.id)) } label: {
                            HStack(spacing: 12) {
                                Avatar(url: c.avatar, size: 42)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.headline).foregroundStyle(.primary)
                                    if let s = c.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    actions(w)

                    if let d = w.description, !d.isEmpty { descriptionCard(d) }

                    if !settings.hideComments, w.commentsToken != nil { commentsCard(w) }

                    if !settings.hideRelated, !w.related.isEmpty {
                        Text("Up Next").font(.title3.weight(.bold)).padding(.top, 4)
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(w.related) { v in
                                VideoRow(video: v).onAppear {
                                    if v.id == w.related.last?.id { Task { await app.loadMoreRelated() } }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 30)
            } else if let error = app.watchError {
                ContentUnavailableView("Couldn't Load Details", systemImage: "exclamationmark.triangle", description: Text(error))
            }
        }
    }

    private func actions(_ w: WatchDetails) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let likes = w.likes {
                    Label(likes, systemImage: "hand.thumbsup").chip()
                }
                if let v = app.player.current {
                    ShareLink(item: v.shareURL) { Label("Share", systemImage: "square.and.arrow.up").chip() }
                        .buttonStyle(.plain)
                }
                Button { app.player.togglePiP() } label: { Label("Picture in Picture", systemImage: "pip.enter").chip() }
                    .buttonStyle(.plain)
                if let v = app.player.current {
                    Button {
                        UIPasteboard.general.url = v.shareURL
                        app.show(Toast(icon: "link", text: "Link copied"))
                    } label: { Label("Copy Link", systemImage: "link").chip() }
                        .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    private func descriptionCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(linkified(text))
                .font(.subheadline)
                .lineLimit(descriptionExpanded ? nil : 3)
                .textSelection(.enabled)
            Text(descriptionExpanded ? "Show less" : "Show more")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { descriptionExpanded.toggle() } }
    }

    private func commentsCard(_ w: WatchDetails) -> some View {
        Button { showComments = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Comments").font(.headline)
                    if let c = w.commentsCount { Text(c).foregroundStyle(.secondary) }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                if let p = w.commentPreview {
                    Text(p).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func linkified(_ text: String) -> AttributedString {
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
}

private extension View {
    func chip() -> some View {
        self.font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular.interactive(), in: Capsule())
    }
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
                            Text(c.text).font(.subheadline).textSelection(.enabled)
                            HStack(spacing: 14) {
                                if let l = c.likes, !l.isEmpty { Label(l, systemImage: "hand.thumbsup") }
                                if c.replies > 0 { Label("\(c.replies)", systemImage: "bubble.left") }
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
