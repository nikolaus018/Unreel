import SwiftUI
import UniformTypeIdentifiers

// MARK: - Feed control

struct FeedControlView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var app: AppModel
    @State private var newKeyword = ""
    @FocusState private var keywordFocused: Bool

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.hideWatched) {
                    SettingLabel("Hide Watched Videos", icon: "eye.slash", color: .blue)
                }
                Toggle(isOn: $settings.hideShorts) {
                    SettingLabel("Hide Shorts", icon: "rectangle.slash", color: .pink)
                }
            } footer: {
                Text("Watched videos (90% or more) are left out of Home, Subscriptions and Up Next. History, playlists and channel pages always show everything.")
            }

            Section {
                ForEach(library.blockedKeywords, id: \.self) { k in
                    Text(k)
                }
                .onDelete { library.removeKeywords(at: $0) }
                HStack {
                    TextField("Add a word or phrase", text: $newKeyword)
                        .focused($keywordFocused)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit(addKeyword)
                    if !newKeyword.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add", action: addKeyword).fontWeight(.semibold)
                    }
                }
            } header: {
                Text("Blocked Words")
            } footer: {
                Text("Videos and playlists whose titles contain one of these words are hidden everywhere except your own lists. Matching ignores case and accents and only counts whole words.")
            }

            Section {
                if library.blockedChannels.isEmpty {
                    Text("Long-press a video and choose Block Channel.").foregroundStyle(.secondary)
                }
                ForEach(library.blockedChannels) { c in
                    HStack(spacing: 12) {
                        if c.avatar != nil { Avatar(url: c.avatar, size: 30) }
                        Text(c.name.isEmpty ? c.id : c.name)
                    }
                }
                .onDelete { idx in idx.map { library.blockedChannels[$0].id }.forEach(library.unblock) }
            } header: {
                Text("Blocked Channels")
            } footer: {
                if !library.blockedChannels.isEmpty { Text("Swipe left to unblock.") }
            }

            Section {
                Button("Show Hidden Videos Again (\(library.hiddenVideos.count))") {
                    library.unhideAll()
                    app.show(Toast(icon: "eye", text: "Hidden videos are back"))
                }
                .disabled(library.hiddenVideos.isEmpty)
            } footer: {
                Text("Long-press a video and choose Hide Video to remove it from your feeds.")
            }
        }
        .navigationTitle("Feed Control")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addKeyword() {
        library.addKeyword(newKeyword)
        newKeyword = ""
        keywordFocused = true
    }
}

// MARK: - Playlists

/// "Save to Playlist": your playlists with a checkmark where the video already is.
struct AddToPlaylistSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let video: VideoItem
    @State private var choices: [InnerTube.PlaylistChoice] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { app.toggleWatchLater(video) } label: {
                        row("Watch Later", icon: "clock", checked: app.watchLater.contains(video.id))
                    }
                }
                Section {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else if choices.isEmpty {
                        Text("You don't have any playlists yet.").foregroundStyle(.secondary)
                    }
                    ForEach(choices) { c in
                        Button { toggle(c) } label: {
                            row(c.title, icon: c.privacy == "PRIVATE" ? "lock" : "list.bullet", checked: c.contains)
                        }
                    }
                } header: {
                    Text("Playlists")
                }
            }
            .tint(.primary)
            .navigationTitle("Save to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Label("New Playlist", systemImage: "plus") }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showNew) {
                NewPlaylistSheet(videoId: video.id) { dismiss() }
            }
        }
    }

    private func row(_ title: String, icon: String, checked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            Text(title).foregroundStyle(.primary)
            Spacer()
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { choices = try await InnerTube.shared.playlistsForAdding(video.id) }
        catch { self.error = "Couldn't load your playlists." }
    }

    private func toggle(_ c: InnerTube.PlaylistChoice) {
        guard let i = choices.firstIndex(of: c) else { return }
        app.haptic()
        let add = !c.contains
        choices[i].contains = add
        Task {
            do {
                try await InnerTube.shared.setInPlaylist(c.id, videoId: video.id, add)
                app.show(Toast(icon: add ? "text.badge.checkmark" : "text.badge.minus", text: add ? "Saved to \(c.title)" : "Removed from \(c.title)"))
            } catch {
                if let j = choices.firstIndex(where: { $0.id == c.id }) { choices[j].contains = !add }
                app.show(Toast(icon: "exclamationmark.triangle", text: "Couldn't update \(c.title)"))
            }
        }
    }
}

struct NewPlaylistSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let videoId: String?
    var onCreated: () -> Void = {}
    @State private var title = ""
    @State private var privacy: InnerTube.Privacy = .PRIVATE
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).focused($focused).submitLabel(.done).onSubmit(create)
                Picker("Visibility", selection: $privacy) {
                    ForEach(InnerTube.Privacy.allCases) { Text($0.title).tag($0) }
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Create", action: create).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !saving else { return }
        saving = true
        Task {
            do {
                try await InnerTube.shared.createPlaylist(title: t, privacy: privacy, videoId: videoId)
                app.successHaptic()
                app.show(Toast(icon: "text.badge.plus", text: videoId == nil ? "Created \(t)" : "Saved to new playlist \(t)"))
                dismiss()
                onCreated()
            } catch {
                saving = false
                app.show(Toast(icon: "exclamationmark.triangle", text: "Couldn't create the playlist"))
            }
        }
    }
}

// MARK: - On this device

struct LocalHistoryView: View {
    @EnvironmentObject private var library: LocalLibrary
    @State private var confirmClear = false
    @State private var query = ""

    private var records: [LocalLibrary.WatchRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.history }
        return library.history.filter { $0.video.title.localizedCaseInsensitiveContains(q) || ($0.video.channelName ?? "").localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let groups = Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.watchedAt) }
            .sorted { $0.key > $1.key }
        ScrollView {
            if library.history.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock.arrow.circlepath",
                                       description: Text("Videos you watch show up here. They're stored only on this device."))
                    .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: .sectionHeaders) {
                    ForEach(groups, id: \.key) { day, items in
                        Section {
                            ForEach(items, id: \.video.id) { r in
                                VideoRow(video: r.video)
                            }
                        } header: {
                            Text(dayTitle(day)).font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .background(.background)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .environment(\.removeAction) { video in library.removeFromHistory([video.id]) }
        .searchable(text: $query, prompt: "Search History")
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !library.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear your watch history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
        } message: {
            Text("Resume positions and watched markers on this device are removed too.")
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

struct LocalChannelsView: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var app: AppModel
    @State private var showImporter = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            if library.subscriptions.isEmpty {
                ContentUnavailableView("No Channels", systemImage: "person.2",
                                       description: Text("Tap Subscribe on a channel to follow it on this device, or import your subscriptions from Google Takeout."))
            }
            ForEach(library.subscriptions) { c in
                ChannelRow(channel: c)
            }
            .onDelete { idx in idx.map { library.subscriptions[$0] }.forEach { library.setSubscribed($0, false) } }
        }
        .listStyle(.plain)
        .navigationTitle("Channels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showImporter = true } label: { Label("Import from Takeout…", systemImage: "square.and.arrow.down") }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Export…", systemImage: "square.and.arrow.up") }
                    }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Import or Export")
            }
        }
        .subscriptionImporter(isPresented: $showImporter)
        .task(id: library.subscriptions) {
            guard !library.subscriptions.isEmpty else { exportURL = nil; return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("subscriptions.csv")
            try? library.exportSubscriptionsCSV().write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        }
    }
}
