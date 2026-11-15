import SafariServices
import SwiftUI
import WebKit

/// Tabs in the system tab bar. The three YouTube tabs share one web view.
enum RootTab: Hashable {
    case web(AppTab)
    case settings
    case search
}

struct RootView: View {
    @EnvironmentObject private var web: WebViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var selection: RootTab = .web(.home)
    @State private var showOnboarding = false

    /// Landscape on a watch page or element fullscreen: video only, no chrome.
    private var immersive: Bool {
        web.isFullscreen || (verticalSizeClass == .compact && web.isWatchPage)
    }

    private var activeWebTab: AppTab {
        if case .web(let tab) = selection { return tab }
        return web.selectedTab
    }

    var body: some View {
        TabView(selection: tabBinding) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.icon, value: RootTab.web(tab)) {
                    webPage(active: selection == .web(tab))
                }
            }
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                SettingsView(embedded: true)
                    .toolbarVisibility(immersive ? .hidden : .visible, for: .tabBar)
            }
            Tab(value: RootTab.search, role: .search) {
                SearchPage(page: webPage(active: selection == .search))
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: web.isWatchPage && web.media != nil && !immersive) {
            VideoAccessory()
        }
        .overlay(alignment: .bottom) {
            if let toast = web.toast {
                ToastView(toast: toast) { web.toast = nil }
                    .padding(.bottom, immersive ? 24 : (web.isWatchPage ? 150 : 96))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .statusBarHidden(immersive)
        .persistentSystemOverlays(web.isFullscreen ? .hidden : .automatic)
        .sheet(item: Binding(get: { web.safariURL.map(IdentifiedURL.init) }, set: { web.safariURL = $0?.url })) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { settings.hasOnboarded = true; showOnboarding = false }
        }
        .onAppear { if !settings.hasOnboarded { showOnboarding = true } }
        .onChange(of: web.selectedTab) { _, tab in
            // Page navigation (links, back gestures) moves the tab bar selection along.
            if case .web = selection { selection = .web(tab) }
        }
    }

    private func webPage(active: Bool) -> some View {
        WebTabHost(webView: web.webView, active: active)
            .ignoresSafeArea(.container, edges: .bottom)
            .overlay(alignment: .top) { LoadingBar(progress: web.progress, visible: web.isLoading) }
            .overlay {
                if let error = web.loadError {
                    ErrorOverlay(message: error) { web.reload() }
                }
            }
            .toolbarVisibility(immersive ? .hidden : .visible, for: .tabBar)
            .background(Color(uiColor: .ytBackground))
    }

    /// Every tap goes through here, including taps on the tab that is already selected.
    private var tabBinding: Binding<RootTab> {
        Binding(
            get: { selection },
            set: { newValue in
                let previous = selection
                switch newValue {
                case .web(let tab):
                    selection = newValue
                    web.select(tab)
                case .search:
                    // The search tab shows the same page with YouTube's search field open.
                    selection = .search
                    if settings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                case .settings:
                    selection = .settings
                }
                if previous == .settings && newValue != .settings { web.applyPendingReload() }
            })
    }
}

/// Native search field (in the tab bar on iOS 26) with YouTube's suggestions; results show in the web view.
private struct SearchPage<Page: View>: View {
    @EnvironmentObject private var web: WebViewModel
    let page: Page
    @State private var query = ""

    var body: some View {
        NavigationStack {
            page
                .toolbarVisibility(.hidden, for: .navigationBar)
        }
        .searchable(text: $query, prompt: "Search YouTube")
        .searchSuggestions {
            ForEach(web.suggestions, id: \.self) { suggestion in
                Label(suggestion, systemImage: "magnifyingglass")
                    .searchCompletion(suggestion)
            }
        }
        .onChange(of: query) { _, q in web.updateSuggestions(for: q) }
        .onSubmit(of: .search) { web.search(query) }
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Web view host

/// Hosts the shared web view. Whichever tab is active takes it into its own container.
struct WebTabHost: UIViewRepresentable {
    let webView: WKWebView
    let active: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .ytBackground
        if active { attach(to: container) }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if active && webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor),
        ])
    }
}

// MARK: - Mini player accessory

/// Shown above the tab bar while a video is open, like a now-playing bar.
struct VideoAccessory: View {
    @EnvironmentObject private var web: WebViewModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let media = web.media
        HStack(spacing: 12) {
            if placement != .inline, let id = media?.videoId {
                AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 52, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(media?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if placement != .inline, let author = media?.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { web.scrollToTop() }

            Button { web.togglePlayback() } label: {
                Image(systemName: media?.playing == true ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel(media?.playing == true ? "Pause" : "Play")

            if placement != .inline {
                Button { web.togglePiP() } label: {
                    Image(systemName: "pip.enter").frame(width: 30, height: 30)
                }
                .accessibilityLabel("Picture in Picture")

                if let url = web.shareURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up").frame(width: 30, height: 30)
                    }
                    .accessibilityLabel("Share")
                }
            }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
    }
}

// MARK: - Loading bar

struct LoadingBar: View {
    let progress: Double
    let visible: Bool

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(8, geo.size.width * progress), height: 2.5)
                .opacity(visible && progress < 1 ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: progress)
                .animation(.easeOut(duration: 0.4), value: visible)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

// MARK: - Error overlay

struct ErrorOverlay: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Load YouTube", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.glassProminent)
        }
        .background(Color(uiColor: .ytBackground))
    }
}

// MARK: - Safari

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(named: "AccentColor")
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
