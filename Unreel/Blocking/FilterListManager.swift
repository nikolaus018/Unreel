import Foundation
import WebKit
import os

/// Downloads, parses and compiles filter lists, and publishes the results for the web view.
@MainActor
final class FilterListManager: ObservableObject {
    struct ListState: Codable, Equatable {
        var lastUpdated: Date?
        var networkRules = 0
        var cosmeticRules = 0
        var scriptletRules = 0
        var lastError: String?
    }

    enum Phase: Equatable {
        case idle
        case downloading(done: Int, total: Int)
        case compiling
        var isBusy: Bool { self != .idle }
    }

    private let log = Logger(subsystem: "com.nikolaus.Unreel", category: "filters")
    private let defaults = UserDefaults.standard

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var states: [String: ListState] = [:]
    @Published private(set) var contentRuleLists: [WKContentRuleList] = []
    @Published private(set) var pageRules = PageRules()
    @Published private(set) var totalNetworkRules = 0
    @Published private(set) var lastBuild: Date?
    @Published private(set) var lastMessage: String?
    @Published private(set) var isReady = false

    @Published var enabledIDs: Set<String> {
        didSet { defaults.set(Array(enabledIDs), forKey: Keys.enabled); scheduleRebuild() }
    }
    @Published var customFilters: String {
        didSet { defaults.set(customFilters, forKey: Keys.custom) }
    }
    @Published var updateInterval: UpdateInterval {
        didSet { defaults.set(updateInterval.rawValue, forKey: Keys.interval) }
    }

    private enum Keys {
        static let enabled = "filters.enabled"
        static let custom = "filters.custom"
        static let interval = "filters.interval"
        static let states = "filters.states"
        static let manifest = "filters.manifest"
        static let lastBuild = "filters.lastBuild"
    }

    private struct Manifest: Codable {
        var identifiers: [String]
        var signature: String
        var totalNetwork: Int
    }

    private var rebuildTask: Task<Void, Never>?
    private var pendingRebuild: Task<Void, Never>?

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var pageRulesURL: URL { directory.appendingPathComponent("page-rules.json") }

    init() {
        if let saved = defaults.array(forKey: Keys.enabled) as? [String] {
            enabledIDs = Set(saved)
        } else {
            enabledIDs = Set(FilterCatalog.lists.filter(\.defaultEnabled).map(\.id))
        }
        customFilters = defaults.string(forKey: Keys.custom) ?? ""
        updateInterval = UpdateInterval(rawValue: defaults.string(forKey: Keys.interval) ?? "") ?? .daily
        if let data = defaults.data(forKey: Keys.states),
           let decoded = try? JSONDecoder().decode([String: ListState].self, from: data) {
            states = decoded
        }
        lastBuild = defaults.object(forKey: Keys.lastBuild) as? Date
    }

    // MARK: Startup

    /// Loads compiled rules from disk, or builds them from bundled/downloaded lists.
    func start() async {
        if await loadCached() {
            isReady = true
        } else {
            await rebuild()
        }
        await updateIfDue()
    }

    private func loadCached() async -> Bool {
        guard let data = defaults.data(forKey: Keys.manifest),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.signature == currentSignature(),
              let lists = await ContentBlockerCompiler.lookUp(manifest.identifiers),
              let rulesData = try? Data(contentsOf: pageRulesURL),
              let rules = try? JSONDecoder().decode(PageRules.self, from: rulesData)
        else { return false }
        contentRuleLists = lists
        pageRules = rules
        totalNetworkRules = manifest.totalNetwork
        return true
    }

    /// Changes whenever the inputs to a build change.
    private func currentSignature() -> String {
        let parts = enabledIDs.sorted().map { id -> String in
            let date = states[id]?.lastUpdated?.timeIntervalSince1970 ?? 0
            return "\(id)@\(Int(date))"
        }
        return (parts + ["custom:\(customFilters.hashValueStable)", "v5"]).joined(separator: ";")
    }

    // MARK: Updating

    var isDue: Bool {
        guard let interval = updateInterval.seconds else { return false }
        let enabled = enabledIDs.compactMap { states[$0]?.lastUpdated }
        guard enabled.count == enabledIDs.count, let oldest = enabled.min() else { return true }
        return Date().timeIntervalSince(oldest) > interval
    }

    func updateIfDue() async {
        if isDue { await updateAll() }
    }

    /// Downloads every enabled list, then rebuilds.
    func updateAll() async {
        guard !phase.isBusy else { return }
        let targets = FilterCatalog.lists.filter { enabledIDs.contains($0.id) }
        phase = .downloading(done: 0, total: targets.count)
        var failures: [String] = []
        var changed = false

        await withTaskGroup(of: (String, Result<String, Error>).self) { group in
            for list in targets {
                group.addTask { (list.id, await Self.download(list.url)) }
            }
            var done = 0
            for await (id, result) in group {
                done += 1
                phase = .downloading(done: done, total: targets.count)
                var state = states[id] ?? ListState()
                switch result {
                case .success(let text):
                    do {
                        try text.write(to: fileURL(id), atomically: true, encoding: .utf8)
                        state.lastUpdated = Date()
                        state.lastError = nil
                        changed = true
                    } catch {
                        state.lastError = error.localizedDescription
                        failures.append(FilterCatalog.info(id)?.name ?? id)
                    }
                case .failure(let error):
                    state.lastError = error.localizedDescription
                    failures.append(FilterCatalog.info(id)?.name ?? id)
                }
                states[id] = state
            }
        }
        saveStates()
        phase = .idle
        if changed || !isReady { await rebuild() }
        lastMessage = failures.isEmpty ? "Filter lists are up to date." : "Couldn't update: \(failures.joined(separator: ", "))"
    }

    private nonisolated static func download(_ url: URL) async -> Result<String, Error> {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            guard let text = String(data: data, encoding: .utf8), text.count > 500,
                  !text.prefix(200).lowercased().contains("<html") else {
                throw URLError(.cannotParseResponse)
            }
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Building

    /// Debounces rebuilds triggered by toggling lists.
    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        pendingRebuild = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            // A newly enabled list that was never downloaded needs fetching first.
            let missing = self.enabledIDs.filter { self.listText($0) == nil }
            if !missing.isEmpty { await self.updateAll() } else { await self.rebuild() }
        }
    }

    func applyCustomFilters() async { await rebuild() }

    func rebuild() async {
        if let rebuildTask { await rebuildTask.value }
        let task = Task { await performRebuild() }
        rebuildTask = task
        await task.value
        rebuildTask = nil
    }

    private func performRebuild() async {
        phase = .compiling
        defer { phase = .idle }

        let inputs: [(id: String, text: String, trusted: Bool)] = FilterCatalog.lists.compactMap { info in
            guard enabledIDs.contains(info.id), let text = listText(info.id) else { return nil }
            return (info.id, text, info.trusted)
        }
        let custom = customFilters

        // Parsing several MB of text happens off the main thread.
        let parsed = await Task.detached(priority: .userInitiated) { () -> ParsedBuild in
            var combined = ParseResult()
            var perList: [String: (Int, Int, Int)] = [:]
            for input in inputs {
                var single = ParseResult()
                FilterParser.parse(input.text, trusted: input.trusted, into: &single)
                single.finalize()
                perList[input.id] = (single.networkCount, single.cosmeticCount, single.scriptletCount)
                FilterParser.parse(input.text, trusted: input.trusted, into: &combined)
            }
            if !custom.isEmpty { FilterParser.parse(custom, trusted: true, into: &combined) }
            combined.finalize()
            let blocks = FilterCatalog.builtInNetworkRules + combined.blocks
            return ParsedBuild(blocks: blocks, allows: combined.allows, page: combined.page, perList: perList,
                               blocksJSON: (try? JSONSerialization.data(withJSONObject: blocks)) ?? Data(),
                               allowsJSON: (try? JSONSerialization.data(withJSONObject: combined.allows)) ?? Data())
        }.value

        let blocks = (try? JSONSerialization.jsonObject(with: parsed.blocksJSON)) as? [[String: Any]] ?? []
        let allows = (try? JSONSerialization.jsonObject(with: parsed.allowsJSON)) as? [[String: Any]] ?? []
        let output = await ContentBlockerCompiler.compile(blocks: blocks, allows: allows, prefix: "unreel-net")
        await ContentBlockerCompiler.removeAll(except: Set(output.identifiers))

        for (id, counts) in parsed.perList {
            var state = states[id] ?? ListState()
            state.networkRules = counts.0
            state.cosmeticRules = counts.1
            state.scriptletRules = counts.2
            states[id] = state
        }
        saveStates()

        contentRuleLists = output.lists
        pageRules = parsed.page
        totalNetworkRules = blocks.count - output.droppedRules
        lastBuild = Date()
        defaults.set(lastBuild, forKey: Keys.lastBuild)
        isReady = true

        if let data = try? JSONEncoder().encode(parsed.page) { try? data.write(to: pageRulesURL, options: .atomic) }
        let manifest = Manifest(identifiers: output.identifiers, signature: currentSignature(), totalNetwork: totalNetworkRules)
        if let data = try? JSONEncoder().encode(manifest) { defaults.set(data, forKey: Keys.manifest) }
        log.notice("Built \(self.totalNetworkRules) network rules, \(parsed.page.cosmetic.count) cosmetic, \(parsed.page.scriptlets.count) scriptlets, dropped \(output.droppedRules)")
    }

    private struct ParsedBuild: @unchecked Sendable {
        var blocks: [[String: Any]]
        var allows: [[String: Any]]
        var page: PageRules
        var perList: [String: (Int, Int, Int)]
        var blocksJSON: Data
        var allowsJSON: Data
    }

    // MARK: Storage

    private func fileURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).txt") }

    /// The downloaded copy if there is one, otherwise the snapshot bundled with the app.
    func listText(_ id: String) -> String? {
        if let text = try? String(contentsOf: fileURL(id), encoding: .utf8) { return text }
        if let url = Bundle.main.url(forResource: id, withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return nil
    }

    func isBundledOnly(_ id: String) -> Bool {
        !FileManager.default.fileExists(atPath: fileURL(id).path) && Bundle.main.url(forResource: id, withExtension: "txt") != nil
    }

    private func saveStates() {
        if let data = try? JSONEncoder().encode(states) { defaults.set(data, forKey: Keys.states) }
    }

    /// Deletes downloaded lists and compiled rules, falling back to the bundled snapshot.
    func resetToDefaults() async {
        for list in FilterCatalog.lists { try? FileManager.default.removeItem(at: fileURL(list.id)) }
        states = [:]
        saveStates()
        enabledIDs = Set(FilterCatalog.lists.filter(\.defaultEnabled).map(\.id))
        pendingRebuild?.cancel()
        await rebuild()
    }
}

extension String {
    /// A hash that stays the same across launches (Swift's `hashValue` is randomly seeded).
    var hashValueStable: UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return hash
    }
}
