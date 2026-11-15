import Foundation

struct FilterListInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let url: URL
    let defaultEnabled: Bool
    /// Lists maintained by uBlock Origin may use trusted scriptlets and `replace=` rules.
    let trusted: Bool
}

enum FilterCatalog {
    static let lists: [FilterListInfo] = [
        .init(id: "ublock-filters", name: "uBlock filters",
              summary: "uBlock Origin's own ad rules, including its YouTube-specific fixes.",
              url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.min.txt")!,
              defaultEnabled: true, trusted: true),
        .init(id: "ublock-quick-fixes", name: "uBlock filters – Quick fixes",
              summary: "Fast-moving fixes, often for YouTube's latest ad changes.",
              url: URL(string: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.min.txt")!,
              defaultEnabled: true, trusted: true),
        .init(id: "ublock-privacy", name: "uBlock filters – Privacy",
              summary: "Blocks tracking and telemetry beyond EasyPrivacy.",
              url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.min.txt")!,
              defaultEnabled: true, trusted: true),
        .init(id: "ublock-unbreak", name: "uBlock filters – Unbreak",
              summary: "Exceptions that undo rules known to break sites.",
              url: URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.min.txt")!,
              defaultEnabled: true, trusted: true),
        .init(id: "easylist", name: "EasyList",
              summary: "The most widely used general ad blocking list.",
              url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt")!,
              defaultEnabled: true, trusted: false),
        .init(id: "easyprivacy", name: "EasyPrivacy",
              summary: "Blocks trackers, analytics and web bugs.",
              url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt")!,
              defaultEnabled: true, trusted: false),
        .init(id: "peter-lowe", name: "Peter Lowe's Ad and tracking server list",
              summary: "A compact list of ad and tracking hosts.",
              url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext")!,
              defaultEnabled: false, trusted: false),
    ]

    static func info(_ id: String) -> FilterListInfo? { lists.first { $0.id == id } }

    /// Network rules that are always active while ad blocking is on, independent of any list.
    /// They cover YouTube's ad and ad-measurement endpoints so blocking works before the first download.
    static let builtInNetworkRules: [[String: Any]] = {
        let blockHosts = [
            "doubleclick.net", "googleadservices.com", "googlesyndication.com", "googletagservices.com",
            "imasdk.googleapis.com", "pagead2.googlesyndication.com", "ade.googlesyndication.com",
            "adservice.google.com", "static.doubleclick.net",
        ]
        var rules: [[String: Any]] = blockHosts.map { host in
            ["trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[/:]",
                         "resource-type": FilterParser.subresourceTypes],
             "action": ["type": "block"]]
        }
        let ytPaths = [
            "youtube\\.com/api/stats/ads", "youtube\\.com/pagead/", "youtube\\.com/ptracking",
            "youtube\\.com/pcs/activeview", "youtube\\.com/get_midroll_", "youtube\\.com/api/stats/qoe\\?.*adformat",
            "youtube\\.com/youtubei/v1/player/ad_break", "youtube\\.com/csi_204\\?.*ad_",
        ]
        rules += ytPaths.map { path in
            ["trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?" + path, "resource-type": FilterParser.subresourceTypes],
             "action": ["type": "block"]]
        }
        return rules
    }()
}

enum UpdateInterval: String, CaseIterable, Identifiable, Codable {
    case daily, every3Days, weekly, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .daily: "Every day"
        case .every3Days: "Every 3 days"
        case .weekly: "Every week"
        case .manual: "Only manually"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .daily: 86_400
        case .every3Days: 3 * 86_400
        case .weekly: 7 * 86_400
        case .manual: nil
        }
    }
}
