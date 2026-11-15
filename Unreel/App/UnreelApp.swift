import SwiftUI

@main
struct UnreelApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var filters: FilterListManager
    @StateObject private var web: WebViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings()
        let filters = FilterListManager()
        _settings = StateObject(wrappedValue: settings)
        _filters = StateObject(wrappedValue: filters)
        _web = StateObject(wrappedValue: WebViewModel(settings: settings, filters: filters))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(filters)
                .environmentObject(web)
                .preferredColorScheme(settings.theme.colorScheme)
                .tint(.accentColor)
                .task { await startUp() }
                .onOpenURL { web.open($0) }
        }
        .onChange(of: scenePhase) { old, phase in
            switch phase {
            case .inactive where old == .active: web.sceneWillResignActive()
            case .background: web.sceneDidEnterBackground()
            case .active:
                web.sceneDidBecomeActive()
                Task { await filters.updateIfDue() }
            default: break
            }
        }
    }

    /// Loads the page as soon as the compiled rules are ready, so the first page is already filtered.
    private func startUp() async {
        let start = Date()
        let rulesTask = Task { await filters.start() }
        while !filters.isReady && Date().timeIntervalSince(start) < 6 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        web.loadStartPage()
        await rulesTask.value
    }
}
