import SwiftUI

/// Loads a paged feed (home, subscriptions, search, channel tab, playlist) from InnerTube.
@MainActor
final class FeedModel: ObservableObject {
    enum Source: Equatable {
        case browse(String, params: String? = nil)
        case search(String, params: String? = nil)
        /// Built on the device (local subscriptions feed); loaded with `loader`.
        case local(String)

        var endpoint: String {
            switch self {
            case .browse, .local: "browse"
            case .search: "search"
            }
        }
    }

    @Published private(set) var items: [FeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var error: String?
    @Published private(set) var loadedOnce = false

    private(set) var source: Source
    private var continuation: String?
    /// Some pages are only filled for the desktop client; remembered per model once detected.
    private var client: InnerTube.Client = .mweb
    private let hideShorts: () -> Bool
    private let filter: ((FeedItem) -> Bool)?
    /// Loads a `.local` source.
    var loader: (() async throws -> [FeedItem])?
    /// Raw response of the first page, for screens that read more than the items (headers).
    private(set) var firstPage: J?
    /// Bumped whenever the source changes, so answers for an older source are thrown away.
    private var generation = 0
    private var reloadTask: Task<Void, Never>?

    init(_ source: Source, hideShorts: @escaping () -> Bool, filter: ((FeedItem) -> Bool)? = nil) {
        self.source = source
        self.hideShorts = hideShorts
        self.filter = filter
    }

    private func apply(_ items: [FeedItem]) -> [FeedItem] {
        guard let filter else { return items }
        return items.filter(filter)
    }

    var canLoadMore: Bool { continuation != nil }

    func setSource(_ s: Source) {
        guard s != source else { return }
        source = s
        generation += 1
        reloadTask?.cancel()
        reloadTask = nil
        isLoading = false
        isLoadingMore = false
        error = nil
        firstPage = nil
        items = []
        continuation = nil
        client = .mweb
        loadedOnce = false
    }

    func loadIfNeeded() async {
        if !loadedOnce && !isLoading { await reload() }
    }

    /// Reloads the first page. On failure or cancellation the current items stay on screen.
    func reload() async {
        // Join a reload that is already running for this source instead of sending a second one.
        if let running = reloadTask { await running.value; return }
        // Run detached from the caller: SwiftUI cancels `.refreshable` tasks when the view
        // updates, which would otherwise abort the request halfway.
        let task = Task { await performReload() }
        reloadTask = task
        await task.value
    }

    private func performReload() async {
        let gen = generation
        isLoading = true
        error = nil
        defer {
            if gen == generation {
                isLoading = false
                loadedOnce = true
                reloadTask = nil
            }
        }
        do {
            var json: J
            var page: FeedPage
            switch source {
            case .browse(let id, let params):
                json = try await InnerTube.shared.browse(id, params: params, client: client)
                page = Parser.feed(json, hideShorts: hideShorts())
                // Some pages are empty for the mobile client but filled for the desktop one.
                if page.items.isEmpty && client == .mweb,
                   let web = try? await InnerTube.shared.browse(id, params: params, client: .web) {
                    let webPage = Parser.feed(web, hideShorts: hideShorts())
                    if !webPage.items.isEmpty { json = web; page = webPage; client = .web }
                }
            case .search(let q, let params):
                json = try await InnerTube.shared.search(q, params: params)
                page = Parser.feed(json, hideShorts: hideShorts())
            case .local:
                json = J(nil)
                page = FeedPage(items: try await loader?() ?? [])
            }
            guard gen == generation else { return }
            let newItems = apply(page.items)
            // An empty answer on a refresh is almost always a hiccup: keep what is shown.
            // (A local feed can legitimately become empty, e.g. after unsubscribing from everything.)
            var isLocal = false
            if case .local = source { isLocal = true }
            if newItems.isEmpty && !items.isEmpty && !isLocal { return }
            firstPage = json
            items = newItems
            continuation = page.continuation
        } catch {
            guard gen == generation else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard let token = continuation, !isLoadingMore, !isLoading else { return }
        let gen = generation
        isLoadingMore = true
        defer { if gen == generation { isLoadingMore = false } }
        guard let json = try? await InnerTube.shared.continuation(source.endpoint, token: token, client: client),
              gen == generation else { return }
        let page = Parser.feed(json, hideShorts: hideShorts())
        let existing = Set(items.map(\.id))
        items += apply(page.items).filter { !existing.contains($0.id) }
        continuation = page.continuation == token ? nil : page.continuation
    }

    /// Triggers paging when one of the last few shown items appears (some may be filtered out).
    func itemAppeared(_ item: FeedItem, in shown: [FeedItem]) {
        guard let index = shown.firstIndex(of: item), index >= shown.count - 5 else { return }
        Task { await loadMore() }
    }

    /// Removes a video right away (after removing it from a playlist).
    func remove(_ videoId: String) {
        items.removeAll { if case .video(let v) = $0 { v.id == videoId } else { false } }
    }

    /// Clears a local feed so the next load starts fresh (e.g. after subscribing).
    func invalidate() {
        loadedOnce = false
    }
}
