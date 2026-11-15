import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum StartPage: String, CaseIterable, Identifiable {
    case home, subscriptions, you
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .subscriptions: "Subscriptions"
        case .you: "You"
        }
    }
    var path: String {
        switch self {
        case .home: "/"
        case .subscriptions: "/feed/subscriptions"
        case .you: "/feed/you"
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case auto, hd2160, hd1440, hd1080, hd720, large, medium, small
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .hd2160: "2160p (4K)"
        case .hd1440: "1440p"
        case .hd1080: "1080p"
        case .hd720: "720p"
        case .large: "480p"
        case .medium: "360p"
        case .small: "240p"
        }
    }
}

enum ExternalLinkTarget: String, CaseIterable, Identifiable {
    case inApp, safari
    var id: String { rawValue }
    var title: String { self == .inApp ? "In Unreel" : "Safari" }
}

struct SponsorCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let defaultOn: Bool

    static let all: [SponsorCategory] = [
        .init(id: "sponsor", title: "Sponsors", detail: "Paid promotions and ad reads", defaultOn: true),
        .init(id: "selfpromo", title: "Self-promotion", detail: "Merch, Patreon, other channels", defaultOn: true),
        .init(id: "interaction", title: "Interaction reminders", detail: "\"Like and subscribe\"", defaultOn: true),
        .init(id: "intro", title: "Intros", detail: "Intro animations and pauses", defaultOn: false),
        .init(id: "outro", title: "Endcards and credits", detail: "", defaultOn: false),
        .init(id: "preview", title: "Previews and recaps", detail: "", defaultOn: false),
        .init(id: "music_offtopic", title: "Non-music in music videos", detail: "", defaultOn: false),
        .init(id: "filler", title: "Filler tangents", detail: "Off-topic jokes and tangents", defaultOn: false),
    ]
}

/// All user preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    // Blocking
    @Published var adBlocking: Bool { didSet { d.set(adBlocking, forKey: "adBlocking") } }
    @Published var listScriptlets: Bool { didSet { d.set(listScriptlets, forKey: "listScriptlets") } }

    // Shorts
    @Published var hideShorts: Bool { didSet { d.set(hideShorts, forKey: "hideShorts") } }
    @Published var redirectShorts: Bool { didSet { d.set(redirectShorts, forKey: "redirectShorts") } }

    // Page clean-up
    @Published var hideComments: Bool { didSet { d.set(hideComments, forKey: "hideComments") } }
    @Published var hideRelated: Bool { didSet { d.set(hideRelated, forKey: "hideRelated") } }
    @Published var hideEndscreen: Bool { didSet { d.set(hideEndscreen, forKey: "hideEndscreen") } }
    @Published var hideMerch: Bool { didSet { d.set(hideMerch, forKey: "hideMerch") } }
    @Published var hidePromos: Bool { didSet { d.set(hidePromos, forKey: "hidePromos") } }
    @Published var hidePlayables: Bool { didSet { d.set(hidePlayables, forKey: "hidePlayables") } }

    // Playback
    @Published var backgroundPlay: Bool { didSet { d.set(backgroundPlay, forKey: "backgroundPlay") } }
    @Published var autoPiP: Bool { didSet { d.set(autoPiP, forKey: "autoPiP") } }
    @Published var defaultSpeed: Double { didSet { d.set(defaultSpeed, forKey: "defaultSpeed") } }
    @Published var quality: VideoQuality { didSet { d.set(quality.rawValue, forKey: "quality") } }
    @Published var autoplayNext: Bool { didSet { d.set(autoplayNext, forKey: "autoplayNext") } }
    @Published var keepScreenOn: Bool { didSet { d.set(keepScreenOn, forKey: "keepScreenOn") } }
    @Published var lockScreenControls: Bool { didSet { d.set(lockScreenControls, forKey: "lockScreenControls") } }

    // SponsorBlock
    @Published var sponsorBlock: Bool { didSet { d.set(sponsorBlock, forKey: "sponsorBlock") } }
    @Published var sponsorCategories: Set<String> { didSet { d.set(Array(sponsorCategories), forKey: "sponsorCategories") } }
    @Published var sponsorNotice: Bool { didSet { d.set(sponsorNotice, forKey: "sponsorNotice") } }
    /// Caption language to turn on automatically; nil means captions off.
    @Published var captionsLanguage: String? { didSet { d.set(captionsLanguage, forKey: "captionsLanguage") } }

    // Appearance and behaviour
    @Published var theme: AppTheme { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var startPage: StartPage { didSet { d.set(startPage.rawValue, forKey: "startPage") } }
    @Published var desktopSite: Bool { didSet { d.set(desktopSite, forKey: "desktopSite") } }
    @Published var pageZoom: Double { didSet { d.set(pageZoom, forKey: "pageZoom") } }
    @Published var pullToRefresh: Bool { didSet { d.set(pullToRefresh, forKey: "pullToRefresh") } }
    @Published var swipeNavigation: Bool { didSet { d.set(swipeNavigation, forKey: "swipeNavigation") } }
    @Published var externalLinks: ExternalLinkTarget { didSet { d.set(externalLinks.rawValue, forKey: "externalLinks") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }

    // Stats & state
    @Published var adsBlockedTotal: Int { didSet { d.set(adsBlockedTotal, forKey: "adsBlockedTotal") } }
    @Published var segmentsSkippedTotal: Int { didSet { d.set(segmentsSkippedTotal, forKey: "segmentsSkippedTotal") } }
    @Published var secondsSavedTotal: Int { didSet { d.set(secondsSavedTotal, forKey: "secondsSavedTotal") } }
    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }

    init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        adBlocking = bool("adBlocking", true)
        listScriptlets = bool("listScriptlets", true)
        hideShorts = bool("hideShorts", true)
        redirectShorts = bool("redirectShorts", true)
        hideComments = bool("hideComments", false)
        hideRelated = bool("hideRelated", false)
        hideEndscreen = bool("hideEndscreen", true)
        hideMerch = bool("hideMerch", true)
        hidePromos = bool("hidePromos", true)
        hidePlayables = bool("hidePlayables", true)
        backgroundPlay = bool("backgroundPlay", true)
        autoPiP = bool("autoPiP", true)
        defaultSpeed = d.object(forKey: "defaultSpeed") == nil ? 1.0 : d.double(forKey: "defaultSpeed")
        quality = VideoQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .auto
        autoplayNext = bool("autoplayNext", true)
        keepScreenOn = bool("keepScreenOn", true)
        lockScreenControls = bool("lockScreenControls", true)
        sponsorBlock = bool("sponsorBlock", true)
        sponsorCategories = Set(d.stringArray(forKey: "sponsorCategories") ?? SponsorCategory.all.filter(\.defaultOn).map(\.id))
        sponsorNotice = bool("sponsorNotice", true)
        captionsLanguage = d.string(forKey: "captionsLanguage")
        theme = AppTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        startPage = StartPage(rawValue: d.string(forKey: "startPage") ?? "") ?? .home
        desktopSite = bool("desktopSite", false)
        pageZoom = d.object(forKey: "pageZoom") == nil ? 1.0 : d.double(forKey: "pageZoom")
        pullToRefresh = bool("pullToRefresh", true)
        swipeNavigation = bool("swipeNavigation", true)
        externalLinks = ExternalLinkTarget(rawValue: d.string(forKey: "externalLinks") ?? "") ?? .inApp
        haptics = bool("haptics", true)
        adsBlockedTotal = d.integer(forKey: "adsBlockedTotal")
        segmentsSkippedTotal = d.integer(forKey: "segmentsSkippedTotal")
        secondsSavedTotal = d.integer(forKey: "secondsSavedTotal")
        hasOnboarded = bool("hasOnboarded", false)
    }

    /// The subset of settings the page engine needs, serialized for injection.
    var pageConfig: [String: Any] {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return [
            "debug": debug,
            "noPrune": debug && UserDefaults.standard.bool(forKey: "debug.noPrune"),
            "adblock": adBlocking,
            "listScriptlets": listScriptlets,
            "hideShorts": hideShorts,
            "redirectShorts": redirectShorts,
            "hideComments": hideComments,
            "hideRelated": hideRelated,
            "hideEndscreen": hideEndscreen,
            "hideMerch": hideMerch,
            "hidePromos": hidePromos,
            "hidePlayables": hidePlayables,
            "nativeTabBar": !desktopSite,
            "backgroundPlay": backgroundPlay,
            "speed": defaultSpeed,
            "quality": quality.rawValue,
            "autoplay": autoplayNext,
            "sponsorBlock": sponsorBlock,
            "sbCategories": sponsorCategories.sorted(),
        ]
    }

    func resetPreferences() {
        let keep = ["adsBlockedTotal", "segmentsSkippedTotal", "secondsSavedTotal", "hasOnboarded"]
        for key in d.dictionaryRepresentation().keys where !keep.contains(key) && !key.hasPrefix("filters.") {
            d.removeObject(forKey: key)
        }
        let fresh = AppSettings()
        adBlocking = fresh.adBlocking; listScriptlets = fresh.listScriptlets
        hideShorts = fresh.hideShorts; redirectShorts = fresh.redirectShorts
        hideComments = fresh.hideComments; hideRelated = fresh.hideRelated; hideEndscreen = fresh.hideEndscreen
        hideMerch = fresh.hideMerch; hidePromos = fresh.hidePromos; hidePlayables = fresh.hidePlayables
        backgroundPlay = fresh.backgroundPlay; autoPiP = fresh.autoPiP; defaultSpeed = fresh.defaultSpeed
        quality = fresh.quality; autoplayNext = fresh.autoplayNext; keepScreenOn = fresh.keepScreenOn
        lockScreenControls = fresh.lockScreenControls
        sponsorBlock = fresh.sponsorBlock; sponsorCategories = fresh.sponsorCategories; sponsorNotice = fresh.sponsorNotice
        theme = fresh.theme; startPage = fresh.startPage; desktopSite = fresh.desktopSite; pageZoom = fresh.pageZoom
        pullToRefresh = fresh.pullToRefresh; swipeNavigation = fresh.swipeNavigation; externalLinks = fresh.externalLinks
        haptics = fresh.haptics
    }
}
