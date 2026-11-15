import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: FeedModel

    init(settings: AppSettings) {
        _model = StateObject(wrappedValue: FeedModel(.browse("FEwhat_to_watch"), hideShorts: { settings.hideShorts }))
    }

    var body: some View {
        FeedList(model: model, style: .cards) {
            ContentUnavailableView {
                Label("Nothing Here Yet", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text(app.signedIn
                     ? "YouTube has no recommendations for you right now. Search for something to watch."
                     : "YouTube recommends videos once you've watched a few or signed in.")
            } actions: {
                Button("Search", systemImage: "magnifyingglass") { app.tab = .search }
                    .buttonStyle(.glassProminent)
                if !app.signedIn {
                    Button("Sign In") { app.showSignIn = true }.buttonStyle(.glass)
                }
            }
        }
        .navigationTitle("Home")
        .toolbar { AccountToolbarItem() }
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
    @StateObject private var model: FeedModel

    init(settings: AppSettings) {
        _model = StateObject(wrappedValue: FeedModel(.browse("FEsubscriptions"), hideShorts: { settings.hideShorts }))
    }

    var body: some View {
        Group {
            if app.signedIn {
                FeedList(model: model, style: .cards, header: { SubscribedChannelsRow() }, empty: {
                    ContentUnavailableView("No New Videos", systemImage: "play.square.stack",
                                           description: Text("Videos from channels you subscribe to show up here."))
                })
            } else {
                SignInPrompt(title: "Your Subscriptions", message: "Sign in to see the latest videos from the channels you follow.", icon: "play.square.stack")
            }
        }
        .navigationTitle("Subscriptions")
        .toolbar {
            if app.signedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.browse("FEchannels", "Channels")) {
                        Image(systemName: "person.2")
                    }
                    .accessibilityLabel("All channels")
                }
            }
        }
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
                            .buttonStyle(.plain)
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
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section {
                if app.signedIn {
                    HStack(spacing: 14) {
                        Avatar(url: app.account?.avatar, size: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.account?.name ?? "Signed in").font(.title3.weight(.semibold))
                            if let h = app.account?.handle { Text(h).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in to see your subscriptions, history, playlists and recommendations.")
                            .foregroundStyle(.secondary)
                        Button("Sign In with Google") { app.showSignIn = true }
                            .buttonStyle(.glassProminent)
                    }
                    .padding(.vertical, 6)
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

            Section("This Device") {
                LabeledContent("Ads blocked", value: settings.adsBlockedTotal.formatted())
                LabeledContent("Sponsor segments skipped", value: settings.segmentsSkippedTotal.formatted())
                LabeledContent("Time saved", value: Duration.seconds(settings.secondsSavedTotal).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
            }

            if app.signedIn {
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                }
            }
        }
        .navigationTitle("You")
        .confirmationDialog("Sign out of YouTube?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
        } message: {
            Text("This also clears the website data stored by the player.")
        }
    }
}

// MARK: - Generic browse page (history, channels list, playlists overview)

struct BrowseView: View {
    @StateObject private var model: FeedModel
    let title: String
    let style: FeedStyle

    init(browseId: String, title: String, settings: AppSettings) {
        // The library page mixes history, Shorts and playlists; the Playlists screen keeps playlists only.
        let filter: ((FeedItem) -> Bool)? = browseId == "FElibrary" ? { if case .playlist = $0 { true } else { false } } : nil
        _model = StateObject(wrappedValue: FeedModel(.browse(browseId), hideShorts: { settings.hideShorts }, filter: filter))
        self.title = title
        style = .rows
    }

    var body: some View {
        FeedList(model: model, style: style) {
            ContentUnavailableView("Nothing Here", systemImage: "tray")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Playlist

struct PlaylistView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: FeedModel
    let title: String

    init(id: String, title: String, settings: AppSettings) {
        _model = StateObject(wrappedValue: FeedModel(.browse("VL" + id), hideShorts: { settings.hideShorts }))
        self.title = title
    }

    var body: some View {
        FeedList(model: model, style: .rows, header: {
            if let first = firstVideo {
                Button {
                    app.play(first)
                } label: {
                    Label("Play All", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }, empty: {
            ContentUnavailableView("Empty Playlist", systemImage: "list.bullet")
        })
        .navigationTitle(playlistTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var firstVideo: VideoItem? {
        for item in model.items { if case .video(let v) = item { return v } }
        return nil
    }

    private var playlistTitle: String {
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
    @AppStorage("recentSearches") private var recentData = Data()
    @StateObject private var model: FeedModel

    init(settings: AppSettings) {
        _model = StateObject(wrappedValue: FeedModel(.search(""), hideShorts: { settings.hideShorts }))
    }

    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: recentData)) ?? [] }

    var body: some View {
        Group {
            if submitted != nil {
                FeedList(model: model, style: .rows) {
                    ContentUnavailableView.search(text: submitted ?? "")
                }
                .id(submitted)
            } else {
                List {
                    if recent.isEmpty {
                        ContentUnavailableView("Search YouTube", systemImage: "magnifyingglass",
                                               description: Text("Find videos, channels and playlists."))
                            .listRowBackground(Color.clear)
                    } else {
                        Section {
                            ForEach(recent, id: \.self) { term in
                                Button {
                                    query = term
                                    submit(term)
                                } label: {
                                    Label(term, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                                }
                            }
                            .onDelete { idx in saveRecent(recent.enumerated().filter { !idx.contains($0.offset) }.map(\.element)) }
                        } header: {
                            HStack {
                                Text("Recent")
                                Spacer()
                                Button("Clear") { saveRecent([]) }.font(.footnote)
                            }
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
                Label {
                    Text(s).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }
                .searchCompletion(s)
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
        submitted = q
        model.setSource(.search(q))
        Task { await model.reload() }
        saveRecent([q] + recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame })
    }

    private func saveRecent(_ list: [String]) {
        recentData = (try? JSONEncoder().encode(Array(list.prefix(15)))) ?? Data()
    }
}

// MARK: - Channel

struct ChannelView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
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
        FeedList(model: model, style: .rows, header: { header }, empty: {
            ContentUnavailableView("No Videos", systemImage: "play.rectangle")
        })
        .navigationTitle(page?.channel.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard page == nil else { return }
            if let json = try? await InnerTube.shared.browse(id) { page = Parser.channelPage(json, id: id) }
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
                SubscribeButton(subscribed: subscribed ?? p.subscribed ?? false) {
                    let new = !(subscribed ?? p.subscribed ?? false)
                    subscribed = new
                    app.setSubscribed(p.channel, new) { subscribed = !new }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
