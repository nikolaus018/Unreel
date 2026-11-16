import SafariServices
import SwiftUI
import WebKit

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var player: PlayerController
    @Namespace private var transition
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $app.tab) {
            Tab("Home", systemImage: "house", value: RootTab.home) {
                NavigationStack(path: $app.homePath) { HomeView(settings: settings).routes() }
            }
            Tab("Subscriptions", systemImage: "play.square.stack", value: RootTab.subscriptions) {
                NavigationStack(path: $app.subscriptionsPath) { SubscriptionsView(settings: settings).routes() }
            }
            Tab("You", systemImage: "person.crop.circle", value: RootTab.you) {
                NavigationStack(path: $app.youPath) { YouView().routes() }
            }
            Tab(value: RootTab.search, role: .search) {
                NavigationStack(path: $app.searchPath) { SearchScreen(settings: settings).routes() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.never)
        .tabViewBottomAccessory(isEnabled: player.current != nil) {
            MiniPlayer(player: player, state: player.state)
                .matchedTransitionSource(id: "player", in: transition)
        }
        .fullScreenCover(isPresented: $app.showPlayer, onDismiss: { player.applyPendingReload() }) {
            WatchView()
                .navigationTransition(.zoom(sourceID: "player", in: transition))
        }
        .sheet(isPresented: $app.showSignIn) {
            SignInView()
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(toast: toast) { app.toast = nil }
                    .padding(.bottom, player.current != nil ? 150 : 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background { ParkingHost(player: player).frame(width: 2, height: 2) }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { settings.hasOnboarded = true; showOnboarding = false }
        }
        .onAppear { if !settings.hasOnboarded { showOnboarding = true } }
    }
}

private struct RouteDestinations: ViewModifier {
    @EnvironmentObject private var settings: AppSettings

    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case .channel(let id): ChannelView(id: id, settings: settings)
            case .playlist(let id, let title): PlaylistView(id: id, title: title, settings: settings)
            case .browse(let id, let title): BrowseView(browseId: id, title: title, settings: settings)
            case .settings: SettingsView()
            }
        }
    }
}

extension View {
    func routes() -> some View { modifier(RouteDestinations()) }
}

// MARK: - Sign in

/// Google sign-in in a web view that shares cookies with the player and the API client.
struct SignInView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        NavigationStack {
            SignInWebView(loading: $loading) {
                dismiss()
                Task { await app.didSignIn() }
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct SignInWebView: UIViewRepresentable {
    @Binding var loading: Bool
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
        config.applicationNameForUserAgent = "Version/\(major).0 Mobile/15E148 Safari/604.1"
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        let next = "https://m.youtube.com/signin?action_handle_signin=true&app=m&next=https%3A%2F%2Fm.youtube.com%2F"
        var comps = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        comps.queryItems = [.init(name: "service", value: "youtube"), .init(name: "passive", value: "true"),
                            .init(name: "uilel", value: "3"), .init(name: "continue", value: next)]
        web.load(URLRequest(url: comps.url!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SignInWebView
        private var finished = false
        init(_ parent: SignInWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            guard !finished, let url = webView.url, let host = url.host else { return }
            // Back on YouTube (not on the sign-in hand-off page) means Google is done.
            if host.hasSuffix("youtube.com") && !url.path.hasPrefix("/signin") {
                finished = true
                parent.onFinish()
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }
    }
}

// MARK: - Safari

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
