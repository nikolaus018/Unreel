import SwiftUI

/// Loads a paged feed (home, subscriptions, search, channel tab, playlist) from InnerTube.
@MainActor
final class FeedModel: ObservableObject {
    enum Source: Equatable {
        case browse(String, params: String? = nil)
        case search(String)

        var endpoint: String {
            switch self {
            case .browse: "browse"
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
    /// Raw response of the first page, for screens that read more than the items (headers).
    private(set) var firstPage: J?

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
        items = []
        continuation = nil
        client = .mweb
        loadedOnce = false
    }

    func loadIfNeeded() async {
        if !loadedOnce && !isLoading { await reload() }
    }

    func reload() async {
        isLoading = true
        error = nil
        defer { isLoading = false; loadedOnce = true }
        do {
            var json: J
            var page: FeedPage
            switch source {
            case .browse(let id, let params):
                do {
                    json = try await InnerTube.shared.browse(id, params: params, client: client)
                    page = Parser.feed(json, hideShorts: hideShorts())
                } catch {
                    guard client == .mweb else { throw error }
                    json = J(nil); page = FeedPage()
                }
                if page.items.isEmpty && client == .mweb {
                    if let web = try? await InnerTube.shared.browse(id, params: params, client: .web) {
                        let webPage = Parser.feed(web, hideShorts: hideShorts())
                        if !webPage.items.isEmpty { json = web; page = webPage; client = .web }
                    }
                }
            case .search(let q):
                json = try await InnerTube.shared.search(q)
                page = Parser.feed(json, hideShorts: hideShorts())
            }
            firstPage = json
            items = apply(page.items)
            continuation = page.continuation
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let token = continuation, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let json = try? await InnerTube.shared.continuation(source.endpoint, token: token, client: client) else { return }
        let page = Parser.feed(json, hideShorts: hideShorts())
        let existing = Set(items.map(\.id))
        items += apply(page.items).filter { !existing.contains($0.id) }
        continuation = page.continuation == token ? nil : page.continuation
    }

    /// Triggers paging when one of the last few items appears.
    func itemAppeared(_ item: FeedItem) {
        guard let index = items.firstIndex(of: item), index >= items.count - 5 else { return }
        Task { await loadMore() }
    }
}
