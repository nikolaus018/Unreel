import SwiftUI

@main
struct UnreelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var filters: FilterListManager
    @StateObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = false

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 400 << 20)
        _ = Orientation.shared
        let settings = AppSettings()
        let filters = FilterListManager()
        _settings = StateObject(wrappedValue: settings)
        _filters = StateObject(wrappedValue: filters)
        _app = StateObject(wrappedValue: AppModel(settings: settings, filters: filters))
    }

    var body: some Scene {
        WindowGroup {
            RootView(player: app.player)
                .environmentObject(settings)
                .environmentObject(filters)
                .environmentObject(app)
                .preferredColorScheme(settings.theme.colorScheme)
                .task { await startUp() }
                .onOpenURL { app.open(url: $0) }
        }
        .onChange(of: scenePhase) { old, phase in
            switch phase {
            case .inactive where old == .active: app.player.sceneWillResignActive()
            case .background: app.player.sceneDidEnterBackground()
            case .active: Task { await filters.updateIfDue() }
            default: break
            }
        }
    }

    /// Runs once: `.task` fires again whenever a full-screen cover is dismissed.
    private func startUp() async {
        guard !started else { return }
        started = true
        app.tab = settings.startPage.tab
        await InnerTube.installConsentCookie()
        await app.refreshAccount()
        await filters.start()
        app.player.prewarm()
    }
}

extension StartPage {
    var tab: RootTab {
        switch self {
        case .home: .home
        case .subscriptions: .subscriptions
        case .you: .you
        }
    }
}
