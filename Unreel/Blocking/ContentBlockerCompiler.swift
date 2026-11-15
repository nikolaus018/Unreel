import Foundation
import WebKit
import os

/// Compiles WebKit content-blocker JSON, splitting large rule sets and isolating rules WebKit rejects.
@MainActor
enum ContentBlockerCompiler {
    private static let log = Logger(subsystem: "com.nikolaus.Unreel", category: "compiler")
    static let chunkSize = 40_000
    private static var store: WKContentRuleListStore { .default() }

    struct Output {
        var lists: [WKContentRuleList]
        var identifiers: [String]
        var droppedRules: Int
    }

    /// Exceptions apply only within their own list, so every chunk carries all exceptions.
    static func compile(blocks: [[String: Any]], allows: [[String: Any]], prefix: String) async -> Output {
        var lists: [WKContentRuleList] = []
        var ids: [String] = []
        var dropped = 0
        let chunks = stride(from: 0, to: max(blocks.count, 1), by: chunkSize).map {
            Array(blocks[$0..<min($0 + chunkSize, blocks.count)])
        }
        for (i, chunk) in chunks.enumerated() where !chunk.isEmpty {
            let id = "\(prefix)-\(i)"
            let (list, lost) = await compileIsolatingFailures(id: id, blocks: chunk, allows: allows)
            dropped += lost
            if let list { lists.append(list); ids.append(id) }
        }
        return Output(lists: lists, identifiers: ids, droppedRules: dropped)
    }

    static func compileSingle(id: String, rules: [[String: Any]]) async -> WKContentRuleList? {
        guard let json = encode(rules) else { return nil }
        return try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)
    }

    static func lookUp(_ ids: [String]) async -> [WKContentRuleList]? {
        var result: [WKContentRuleList] = []
        for id in ids {
            guard let list = try? await store.contentRuleList(forIdentifier: id) else { return nil }
            result.append(list)
        }
        return result
    }

    static func removeAll(except keep: Set<String>) async {
        let ids = await store.availableIdentifiers() ?? []
        for id in ids where !keep.contains(id) {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
    }

    // MARK: Private

    private static func encode(_ rules: [[String: Any]]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func tryCompile(id: String, rules: [[String: Any]]) async -> (WKContentRuleList?, Error?) {
        guard let json = encode(rules) else { return (nil, nil) }
        do {
            return (try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json), nil)
        } catch {
            return (nil, error)
        }
    }

    /// Compiles a chunk; if WebKit rejects it, bisects to find and drop the offending rules.
    private static func compileIsolatingFailures(id: String, blocks: [[String: Any]], allows: [[String: Any]]) async -> (WKContentRuleList?, Int) {
        let (list, error) = await tryCompile(id: id, rules: blocks + allows)
        if let list { return (list, 0) }
        log.error("Chunk \(id, privacy: .public) failed: \(String(describing: error), privacy: .public). Isolating bad rules.")

        let probeID = "unreel-probe"
        var good: [[String: Any]] = []
        var lost = 0
        func bisect(_ rules: ArraySlice<[String: Any]>, depth: Int) async {
            if rules.isEmpty { return }
            let (ok, _) = await tryCompile(id: probeID, rules: Array(rules))
            if ok != nil { good += rules; return }
            if rules.count == 1 || depth > 24 { lost += rules.count; return }
            let mid = rules.startIndex + rules.count / 2
            await bisect(rules[rules.startIndex..<mid], depth: depth + 1)
            await bisect(rules[mid..<rules.endIndex], depth: depth + 1)
        }
        // Check the exceptions on their own first so a broken one doesn't poison every chunk.
        var cleanAllows = allows
        if !allows.isEmpty, await tryCompile(id: probeID, rules: allows).0 == nil {
            await bisect(allows[...], depth: 0)
            cleanAllows = good
            good = []
        }
        await bisect(blocks[...], depth: 0)
        try? await store.removeContentRuleList(forIdentifier: probeID)
        let (final, _) = await tryCompile(id: id, rules: good + cleanAllows)
        log.notice("Chunk \(id, privacy: .public): dropped \(lost) rules")
        return (final, lost)
    }
}
