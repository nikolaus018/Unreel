import SwiftUI
import UniformTypeIdentifiers

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @StateObject private var model: FeedModel
    /// Without an account YouTube's Home is empty; this one is built on the device instead.
    @StateObject private var localModel: FeedModel

    init(settings: AppSettings, library: LocalLibrary) {
        _model = StateObject(wrappedValue: FeedModel(.browse("FEwhat_to_watch"), hideShorts: { settings.hideShorts }))
        let local = FeedModel(.local("home"), hideShorts: { settings.hideShorts })
        local.loader = { [weak library] in
            guard let library else { return [] }
            let (recent, channels, watched) = await MainActor.run {
                (library.history.prefix(8).map(\.video), library.subscriptions,
                 Set(library.history.filter { $0.fraction >= 0.9 }.map(\.video.id)))
            }
            return await LocalFeeds.shared.home(recent: recent, channels: channels, hideShorts: settings.hideShorts, exclude: watched)
                .map(FeedItem.video)
        }
        _localModel = StateObject(wrappedValue: local)
    }

    private var useLocal: Bool { !app.signedIn && (!library.history.isEmpty || !library.subscriptions.isEmpty) }

    var body: some View {
        FeedList(model: useLocal ? localModel : model, style: .cards, filtering: .discovery, header: { ExploreChips() }, empty: {
            ContentUnavailableView {
                Label("Nothing Here Yet", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text(app.signedIn
                     ? "YouTube has no recommendations for you right now. Search for something to watch."
                     : "Watch a few videos or subscribe to channels, and Home fills with recommendations — no account needed.")
            } actions: {
                Button("Search", systemImage: "magnifyingglass") { app.tab = .search }
                    .buttonStyle(.glassProminent)
                if !app.signedIn {
                    Button("Sign In") { app.showSignIn = true }.buttonStyle(.glass)
                }
            }
        })
        .id(useLocal)
        .navigationTitle("Home")
        .toolbar { AccountToolbarItem() }
    }
}

/// YouTube's Explore destinations as chips above the Home feed.
struct ExploreChips: View {
    private let chips: [(title: String, icon: String, route: Route)] = [
        ("Music", "music.note", .browse("UC-9-kyTW8ZkZNDHQJ6FgpwQ", "Music")),
        ("Gaming", "gamecontroller", .browse("UCOpNcN46UbXVtpKMrmU4Abg", "Gaming")),
        ("Podcasts", "mic", .browse("FEpodcasts_destination", "Podcasts")),
        ("News", "newspaper", .browse("UCYfdidRxbB8Qhf0Nx7ioOYw", "News")),
        ("Sports", "sportscourt", .browse("UCEgdi0XIXXZ-qJOFPf4JSKw", "Sports")),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.title) { chip in
                    NavigationLink(value: chip.route) {
                        Label(chip.title, systemImage: chip.icon)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
        .padding(.bottom, 14)
    }
}

struct AccountToolbarItem: ToolbarContent {
    @EnvironmentObject private var app: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                app.tab = .you
            } label: {
                if let url = app.account?.avatar {
                    Avatar(url: url, size: 30)
                } else {
                    Image(systemName: "person.crop.circle")
                }
            }
            .accessibilityLabel("Account")
        }
    }
}

// MARK: - Subscriptions

struct SubscriptionsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @StateObject private var model: FeedModel
    @StateObject private var localModel: FeedModel
    @State private var showImporter = false

    init(settings: AppSettings, library: LocalLibrary) {
        _model = StateObject(wrappedValue: FeedModel(.browse("FEsubscriptions"), hideShorts: { settings.hideShorts }))
        let local = FeedModel(.local("subscriptions"), hideShorts: { settings.hideShorts })
        local.loader = { [weak library] in
            guard let library else { return [] }
            let channels = await MainActor.run { library.subscriptions }
            return try await LocalFeeds.shared.subscriptions(channels, hideShorts: settings.hideShorts).map(FeedItem.video)
        }
        _localModel = StateObject(wrappedValue: local)
    }

    var body: some View {
        Group {
            if app.signedIn {
                FeedList(model: model, style: .cards, filtering: .discovery, header: { SubscribedChannelsRow() }, empty: {
                    ContentUnavailableView("No New Videos", systemImage: "play.square.stack",
                                           description: Text("Videos from channels you subscribe to show up here."))
                })
            } else if library.subscriptions.isEmpty {
                ContentUnavailableView {
                    Label("Your Subscriptions", systemImage: "play.square.stack")
                } description: {
                    Text("Tap Subscribe on any channel to follow it on this device — no account needed. You can also import your subscriptions from Google Takeout, or sign in.")
                } actions: {
                    Button("Import from Takeout…", systemImage: "square.and.arrow.down") { showImporter = true }
                        .buttonStyle(.glassProminent)
                    Button("Sign In with Google") { app.showSignIn = true }
                        .buttonStyle(.glass)
                }
            } else {
                FeedList(model: localModel, style: .cards, filtering: .discovery, header: { LocalChannelsRow() }, empty: {
                    ContentUnavailableView("No Videos", systemImage: "play.square.stack",
                                           description: Text("The channels you follow haven't posted any videos yet."))
                })
                .onChange(of: library.subscriptions) { Task { await localModel.reload() } }
            }
        }
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: app.signedIn ? Route.browse("FEchannels", "Channels") : Route.localChannels) {
                    Image(systemName: "person.2")
                }
                .accessibilityLabel("All channels")
            }
        }
        .subscriptionImporter(isPresented: $showImporter)
    }
}

/// Picks a Google Takeout subscriptions.csv and imports it into the local subscriptions.
private struct SubscriptionImporter: ViewModifier {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                app.show(Toast(icon: "exclamationmark.triangle", text: "Couldn't read that file"))
                return
            }
            let n = library.importSubscriptions(csv: text)
            app.show(Toast(icon: n > 0 ? "checkmark.circle.fill" : "info.circle",
                           text: n > 0 ? "Imported \(n) channel\(n == 1 ? "" : "s")" : "No new channels in that file"))
        }
    }
}

extension View {
    func subscriptionImporter(isPresented: Binding<Bool>) -> some View {
        modifier(SubscriptionImporter(isPresented: isPresented))
    }
}

/// The locally followed channels as a row above the local Subscriptions feed.
struct LocalChannelsRow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(library.subscriptions) { c in
                    Button { app.open(.channel(c.id)) } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(Color.secondary.opacity(0.15))
                                Text(c.name.prefix(1)).font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                                if c.avatar != nil { Avatar(url: c.avatar, size: 58) }
                            }
                            .frame(width: 58, height: 58)
                            Text(c.name.isEmpty ? "Channel" : c.name).font(.caption2).lineLimit(1).frame(width: 64).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(c.name)
                    .accessibilityHint("Opens the channel")
                }
                NavigationLink(value: Route.localChannels) {
                    VStack(spacing: 6) {
                        Image(systemName: "ellipsis").font(.title3.weight(.semibold))
                            .frame(width: 58, height: 58)
                            .glassEffect(.regular.interactive(), in: Circle())
                        Text("All").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All channels")
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 14)
    }
}

/// Horizontal row of subscribed channels, like the top of YouTube's Subscriptions tab.
struct SubscribedChannelsRow: View {
    @EnvironmentObject private var app: AppModel
    @State private var channels: [ChannelItem] = []

    var body: some View {
        VStack(spacing: 0) {
            if !channels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(channels) { c in
                            Button { app.open(.channel(c.id)) } label: {
                                VStack(spacing: 6) {
                                    Avatar(url: c.avatar, size: 58)
                                    Text(c.name).font(.caption2).lineLimit(1).frame(width: 64).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(c.name)
                            .accessibilityHint("Opens the channel")
                        }
                        NavigationLink(value: Route.browse("FEchannels", "Channels")) {
                            VStack(spacing: 6) {
                                Image(systemName: "ellipsis").font(.title3.weight(.semibold))
                                    .frame(width: 58, height: 58)
                                    .glassEffect(.regular.interactive(), in: Circle())
                                Text("All").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("All channels")
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 1)
        .task(id: app.feedGeneration) {
            guard let json = try? await InnerTube.shared.browse("FEchannels") else { return }
            channels = Parser.feed(json, hideShorts: true).items.compactMap { if case .channel(let c) = $0 { return c } else { return nil } }
        }
    }
}

struct SignInPrompt: View {
    @EnvironmentObject private var app: AppModel
    let title: String
    let message: String
    let icon: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            Button("Sign In with Google") { app.showSignIn = true }
                .buttonStyle(.glassProminent)
        }
    }
}

// MARK: - You

struct YouView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section {
                if app.signedIn {
                    HStack(spacing: 14) {
                        Avatar(url: app.account?.avatar, size: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.account?.name ?? "Signed In").font(.title3.weight(.semibold))
                            if let h = app.account?.handle { Text(h).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(.largeTitle))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Not Signed In").font(.headline)
                                Text("Sign in to see your subscriptions, history, playlists and recommendations.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button { app.showSignIn = true } label: {
                            Text("Sign In with Google").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                StatsCard()
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Counted on this device since you installed Unreel.")
            }

            if !app.signedIn {
                Section {
                    NavigationLink(value: Route.localHistory) {
                        LabeledContent { Text("\(library.history.count)") } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    }
                    NavigationLink(value: Route.localChannels) {
                        LabeledContent { Text("\(library.subscriptions.count)") } label: { Label("Channels", systemImage: "person.2") }
                    }
                } header: {
                    Text("On This Device")
                } footer: {
                    Text("Without an account, your history and subscriptions are kept only on this iPhone.")
                }
            }

            if app.signedIn {
                Section("Library") {
                    NavigationLink(value: Route.browse("FEhistory", "History")) { Label("History", systemImage: "clock.arrow.circlepath") }
                    NavigationLink(value: Route.playlist("WL", "Watch Later")) { Label("Watch Later", systemImage: "clock") }
                    NavigationLink(value: Route.playlist("LL", "Liked Videos")) { Label("Liked Videos", systemImage: "hand.thumbsup") }
                    NavigationLink(value: Route.browse("FElibrary", "Playlists")) { Label("Playlists", systemImage: "list.bullet.rectangle") }
                    NavigationLink(value: Route.browse("FEchannels", "Channels")) { Label("Channels", systemImage: "person.2") }
                }
            }

            Section {
                NavigationLink(value: Route.feedControl) { Label("Feed Control", systemImage: "line.3.horizontal.decrease.circle") }
                NavigationLink(value: Route.settings) { Label("Settings", systemImage: "gearshape") }
            }

            if app.signedIn {
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                }
            }
        }
        .navigationTitle("You")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .confirmationDialog("Sign out of YouTube?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
        } message: {
            Text("This also clears the website data stored by the player.")
        }
    }
}

// MARK: - Generic browse page (history, channels list, playlists overview)

struct BrowseView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: FeedModel
    @State private var showNewPlaylist = false
    let browseId: String
    let title: String
    let style: FeedStyle

    init(browseId: String, title: String, settings: AppSettings) {
        // The library page mixes history, Shorts and playlists; the Playlists screen keeps playlists only.
        let filter: ((FeedItem) -> Bool)? = browseId == "FElibrary" ? { if case .playlist = $0 { true } else { false } } : nil
        _model = StateObject(wrappedValue: FeedModel(.browse(browseId), hideShorts: { settings.hideShorts }, filter: filter))
        self.title = title
        self.browseId = browseId
        style = browseId.hasPrefix("FE") && browseId != "FEpodcasts_destination" ? .rows : .cards
    }

    var body: some View {
        FeedList(model: model, style: style, filtering: ["FEhistory", "FElibrary", "FEchannels"].contains(browseId) ? .none : .standard) {
            ContentUnavailableView("Nothing Here", systemImage: "tray")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if browseId == "FElibrary" && app.signedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewPlaylist = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New Playlist")
                }
            }
        }
        .sheet(isPresented: $showNewPlaylist) {
            NewPlaylistSheet(videoId: nil) { Task { await model.reload() } }
        }
    }
}

// MARK: - Playlist

struct PlaylistView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: FeedModel
    let id: String
    let title: String
    @State private var renamed: String?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    init(id: String, title: String, settings: AppSettings) {
        _model = StateObject(wrappedValue: FeedModel(.browse("VL" + id), hideShorts: { settings.hideShorts }))
        self.id = id
        self.title = title
    }

    /// Your own playlists can be edited; YouTube rejects edits to anyone else's.
    private var editable: Bool { app.signedIn && (id.hasPrefix("PL") || id == "WL") }

    private var videos: [VideoItem] {
        model.items.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
    }

    var body: some View {
        FeedList(model: model, style: .rows, filtering: .none, header: { header }, empty: {
            ContentUnavailableView("Empty Playlist", systemImage: "list.bullet")
        })
        .environment(\.playAction) { video in
            let list = videos
            app.play(video, queue: PlayQueue(title: playlistTitle, items: list, index: list.firstIndex(of: video) ?? 0))
        }
        .environment(\.removeAction, editable ? { video in remove(video) } : nil)
        .navigationTitle(playlistTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editable && id != "WL" {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { renameText = playlistTitle; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Playlist Options")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename(renameText) }
        }
        .confirmationDialog("Delete “\(playlistTitle)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { delete() }
        } message: {
            Text("This deletes the playlist from your YouTube account. It can't be undone.")
        }
    }

    private func remove(_ video: VideoItem) {
        app.haptic()
        model.remove(video.id)
        Task {
            do {
                try await InnerTube.shared.setInPlaylist(id, videoId: video.id, false)
                app.show(Toast(icon: "minus.circle", text: "Removed from \(playlistTitle)"))
            } catch {
                await model.reload()
                app.show(Toast(icon: "exclamationmark.triangle", text: "Couldn't remove the video"))
            }
        }
    }

    private func rename(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != playlistTitle else { return }
        let old = renamed
        renamed = t
        Task {
            do { try await InnerTube.shared.renamePlaylist(id, title: t) }
            catch {
                renamed = old
                app.show(Toast(icon: "exclamationmark.triangle", text: "Couldn't rename the playlist"))
            }
        }
    }

    private func delete() {
        Task {
            do {
                try await InnerTube.shared.deletePlaylist(id)
                app.show(Toast(icon: "trash", text: "Playlist deleted"))
                dismiss()
            } catch {
                app.show(Toast(icon: "exclamationmark.triangle", text: "Couldn't delete the playlist"))
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let first = videos.first {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Thumbnail(video: first, cornerRadius: 12, small: true)
                        .frame(width: 128)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlistTitle).font(.title3.weight(.bold)).lineLimit(3)
                        Text("\(videos.count)\(model.canLoadMore ? "+" : "") videos").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Button {
                        app.play(first, queue: PlayQueue(title: playlistTitle, items: videos, index: 0))
                    } label: {
                        Label("Play All", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        let shuffled = videos.shuffled()
                        app.play(shuffled[0], queue: PlayQueue(title: playlistTitle, items: shuffled, index: 0))
                    } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                }
                .font(.headline)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var playlistTitle: String {
        if let renamed { return renamed }
        if title == "Playlist", let t = model.firstPage?["header"].first("title").text { return t }
        return title
    }
}

// MARK: - Search

struct SearchScreen: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @State private var submitted: String?
    @State private var suggestions: [String] = []
    @State private var filter: SearchFilter = .all
    @AppStorage("recentSearches") private var recentData = Data()
    @StateObject private var model: FeedModel

    init(settings: AppSettings) {
        _model = StateObject(wrappedValue: FeedModel(.search(""), hideShorts: { settings.hideShorts }))
    }

    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: recentData)) ?? [] }

    var body: some View {
        Group {
            if submitted != nil {
                FeedList(model: model, style: .rows, header: { filterChips }, empty: {
                    ContentUnavailableView.search(text: submitted ?? "")
                })
                .id(submitted)
            } else {
                List {
                    if recent.isEmpty {
                        ContentUnavailableView {
                            Label("Search YouTube", systemImage: "magnifyingglass")
                        } description: {
                            Text("Find videos, channels and playlists, or paste a YouTube link to open it.")
                        } actions: {
                            pasteLinkButton
                                .buttonBorderShape(.capsule)
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        Section {
                            ForEach(recent, id: \.self) { term in
                                Button {
                                    query = term
                                    submit(term)
                                } label: {
                                    Label {
                                        Text(term).foregroundStyle(.primary)
                                    } icon: {
                                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                    }
                                }
                                .tint(.primary)
                            }
                            .onDelete { idx in saveRecent(recent.enumerated().filter { !idx.contains($0.offset) }.map(\.element)) }
                        } header: {
                            HStack {
                                Text("Recent")
                                Spacer()
                                Button("Clear") { withAnimation { saveRecent([]) } }
                                    .font(.footnote.weight(.semibold))
                                    .accessibilityLabel("Clear recent searches")
                            }
                        }

                        Section {
                            pasteLinkButton
                                .buttonBorderShape(.capsule)
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                        } footer: {
                            Text("Copy a YouTube link in another app, then paste it here to open it.")
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .scrollDismissesKeyboard(.immediately)
        .searchable(text: $query, prompt: "Search YouTube")
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { s in
                // Tapping a suggestion searches right away.
                Button {
                    query = s
                    submit(s)
                } label: {
                    Label {
                        Text(s).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
        }
        .onSubmit(of: .search) { submit(query) }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            if q.isEmpty { submitted = nil; suggestions = []; return }
            guard q.count >= 2, q != submitted else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            suggestions = await InnerTube.shared.suggestions(q)
        }
    }

    private func submit(_ term: String) {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        suggestions = []
        let resubmit = submitted == q
        submitted = q
        model.setSource(.search(q, params: filter.params))
        // A new query creates a new list, which loads itself; the same query needs a nudge.
        if resubmit { Task { await model.reload() } }
        saveRecent([q] + recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame })
    }

    /// The system paste button: reads the clipboard only when tapped, so no paste prompt appears.
    private var pasteLinkButton: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first else { return }
            Task { @MainActor in app.openYouTubeLink(in: text) }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { f in
                    Button {
                        guard f != filter, let q = submitted else { return }
                        filter = f
                        app.haptic()
                        model.setSource(.search(q, params: f.params))
                        Task { await model.reload() }
                    } label: {
                        Group {
                            if f == filter {
                                Text(f.title)
                                    .padding(.horizontal, 14).frame(height: 32)
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                                    .background(Color.primary, in: Capsule())
                            } else {
                                Text(f.title)
                                    .padding(.horizontal, 14).frame(height: 32)
                                    .glassEffect(.regular.interactive(), in: Capsule())
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(f == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
        .padding(.bottom, 12)
    }

    private func saveRecent(_ list: [String]) {
        recentData = (try? JSONEncoder().encode(Array(list.prefix(15)))) ?? Data()
    }
}

enum SearchFilter: String, CaseIterable, Identifiable {
    case all, videos, channels, playlists, live
    var id: String { rawValue }
    var title: String { rawValue == "all" ? "All" : rawValue.capitalized }
    /// InnerTube search parameters (protobuf, URL-encoded as the web client sends them).
    var params: String? {
        switch self {
        case .all: nil
        case .videos: "EgIQAQ%3D%3D"
        case .channels: "EgIQAg%3D%3D"
        case .playlists: "EgIQAw%3D%3D"
        case .live: "EgJAAQ%3D%3D"
        }
    }
}

// MARK: - Channel

struct ChannelView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LocalLibrary
    let id: String
    @State private var page: ChannelPage?
    @State private var tab: ChannelTab?
    @State private var subscribed: Bool?
    @StateObject private var model: FeedModel

    init(id: String, settings: AppSettings) {
        self.id = id
        _model = StateObject(wrappedValue: FeedModel(.browse(id, params: "EgZ2aWRlb3PyBgQKAjoA"), hideShorts: { settings.hideShorts }))
    }

    private var tabs: [ChannelTab] {
        let wanted = ["Videos", "Live", "Playlists"] + (settings.hideShorts ? [] : ["Shorts"])
        return (page?.tabs ?? []).filter { wanted.contains($0.title) }
    }

    var body: some View {
        FeedList(model: model, style: .rows, filtering: .none, header: { header }, empty: {
            ContentUnavailableView("No Videos", systemImage: "play.rectangle")
        })
        .navigationTitle(page?.channel.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard page == nil else { return }
            if let json = try? await InnerTube.shared.browse(id) {
                page = Parser.channelPage(json, id: id)
                if let c = page?.channel { library.refresh(c) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: URL(string: "https://www.youtube.com/channel/\(id)")!)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 14) {
            if let banner = page?.banner {
                Color.clear
                    .aspectRatio(6.2, contentMode: .fit)
                    .overlay { RemoteImage(url: banner) }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(spacing: 14) {
                Avatar(url: page?.channel.avatar, size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page?.channel.name ?? " ").font(.title2.weight(.bold)).lineLimit(2)
                    if let h = page?.handle { Text(h).font(.subheadline).foregroundStyle(.secondary) }
                    let d = (page?.details ?? []).prefix(2).joined(separator: " · ")
                    if !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            if let p = page {
                let current = subscribed ?? (app.signedIn ? p.subscribed : library.isSubscribed(p.channel.id)) ?? false
                HStack(spacing: 10) {
                    SubscribeButton(subscribed: current) {
                        subscribed = !current
                        app.setSubscribed(p.channel, !current) { subscribed = current }
                    }
                    Spacer()
                    Menu {
                        if library.isBlocked(channelId: p.channel.id, name: nil) {
                            Button { library.unblock(p.channel.id) } label: { Label("Unblock Channel", systemImage: "person.crop.circle.badge.checkmark") }
                        } else {
                            Button(role: .destructive) { app.block(p.channel) } label: { Label("Block Channel", systemImage: "person.crop.circle.badge.xmark") }
                        }
                        if let speed = library.speed(for: p.channel.id) {
                            Button { library.setSpeed(settings.defaultSpeed, for: p.channel.id, defaultSpeed: settings.defaultSpeed) } label: {
                                Label("Forget Speed (\(String(format: "%g×", speed)))", systemImage: "gauge.with.dots.needle.33percent")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 40, height: 40).glassEffect(.regular.interactive(), in: Circle())
                    }
                    .accessibilityLabel("More")
                }
            }
            if tabs.count > 1 {
                Picker("Section", selection: Binding(get: { tab ?? tabs.first }, set: { new in
                    tab = new
                    if let new { model.setSource(.browse(id, params: new.params)); Task { await model.reload() } }
                })) {
                    ForEach(tabs) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .redacted(reason: page == nil ? .placeholder : [])
    }
}
