import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var filters: FilterListManager
    @EnvironmentObject private var app: AppModel
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                StatsHeader()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                Section {
                    Toggle(isOn: $settings.adBlocking) {
                        SettingLabel("Block ads", icon: "shield.lefthalf.filled", color: .red)
                    }
                    NavigationLink {
                        FilterListsView()
                    } label: {
                        SettingLabel("Filter lists", icon: "list.bullet.rectangle", color: .orange, detail: filterSummary)
                    }
                    .disabled(!settings.adBlocking)
                } header: {
                    Text("Ad blocking")
                } footer: {
                    Text("Ads are removed from YouTube's data before the player sees them, and filter lists from uBlock Origin and EasyList block ad and tracking requests. Lists update automatically.")
                }

                Section {
                    Toggle(isOn: $settings.hideShorts) {
                        SettingLabel("Hide Shorts", icon: "rectangle.slash", color: .pink)
                    }
                } header: {
                    Text("Shorts")
                } footer: {
                    Text("Shorts are left out of every feed, search and channel. Links to Shorts still open, in the regular player.")
                }

                Section {
                    Toggle(isOn: $settings.sponsorBlock) {
                        SettingLabel("Skip sponsored segments", icon: "forward.end.alt", color: .green)
                    }
                    if settings.sponsorBlock {
                        NavigationLink {
                            SponsorCategoriesView()
                        } label: {
                            SettingLabel("Segments to skip", icon: "checklist", color: .teal, detail: "\(settings.sponsorCategories.count)")
                        }
                        Toggle(isOn: $settings.sponsorNotice) {
                            SettingLabel("Show a notice when skipping", icon: "text.bubble", color: .mint)
                        }
                    }
                } header: {
                    Text("SponsorBlock")
                } footer: {
                    Text("Segments are submitted by the SponsorBlock community. Only the first characters of a hash of the video ID are sent.")
                }

                Section("Playback") {
                    Toggle(isOn: $settings.backgroundPlay) {
                        SettingLabel("Background playback", icon: "headphones", color: .indigo)
                    }
                    Toggle(isOn: $settings.autoPiP) {
                        SettingLabel("Picture in Picture on leave", icon: "pip", color: .blue)
                    }
                    Picker(selection: $settings.defaultSpeed) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { s in
                            Text(s == 1 ? "Normal" : String(format: "%gx", s)).tag(s)
                        }
                    } label: {
                        SettingLabel("Default speed", icon: "gauge.with.dots.needle.67percent", color: .orange)
                    }
                    Picker(selection: $settings.quality) {
                        ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingLabel("Preferred quality", icon: "sparkles.tv", color: .cyan)
                    }
                    Toggle(isOn: $settings.autoplayNext) {
                        SettingLabel("Autoplay next video", icon: "play.circle", color: .red)
                    }
                    Toggle(isOn: $settings.keepScreenOn) {
                        SettingLabel("Keep screen on while playing", icon: "sun.max", color: .yellow)
                    }
                    Toggle(isOn: $settings.lockScreenControls) {
                        SettingLabel("Lock screen controls", icon: "lock.rectangle.on.rectangle", color: .gray)
                    }
                }

                Section("Watch page") {
                    Toggle(isOn: $settings.hideComments) { SettingLabel("Hide comments", icon: "text.bubble", color: .blue) }
                    Toggle(isOn: $settings.hideRelated) { SettingLabel("Hide Up Next", icon: "square.stack", color: .gray) }
                }

                Section("App") {
                    Picker(selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingLabel("Theme", icon: "circle.lefthalf.filled", color: .indigo)
                    }
                    Picker(selection: $settings.startPage) {
                        ForEach(StartPage.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingLabel("Start tab", icon: "house", color: .red)
                    }
                    Toggle(isOn: $settings.haptics) { SettingLabel("Haptic feedback", icon: "waveform", color: .pink) }
                    Button {
                        openCopiedLink()
                    } label: {
                        SettingLabel("Open copied YouTube link", icon: "doc.on.clipboard", color: .red)
                    }
                }

                Section {
                    Button {
                        Task { await app.clearCache() }
                    } label: {
                        SettingLabel("Clear cache", icon: "trash", color: .gray)
                    }
                } header: {
                    Text("Data")
                }

                Section("Advanced") {
                    Toggle(isOn: $settings.listScriptlets) {
                        SettingLabel("Run filter-list scriptlets", icon: "curlybraces", color: .purple)
                    }
                    NavigationLink {
                        CustomFiltersView()
                    } label: {
                        SettingLabel("My filters", icon: "pencil.and.list.clipboard", color: .orange,
                                     detail: filters.customFilters.isEmpty ? "None" : "\(customRuleCount)")
                    }
                    Button(role: .destructive) { confirmReset = true } label: {
                        SettingLabel("Reset all settings", icon: "arrow.counterclockwise", color: .red)
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    Link(destination: URL(string: "https://github.com/nikolaus018/Unreel")!) {
                        SettingLabel("Source code", icon: "chevron.left.forwardslash.chevron.right", color: .black)
                    }
                    NavigationLink { AcknowledgementsView() } label: {
                        SettingLabel("Acknowledgements", icon: "heart", color: .pink)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Settings", role: .destructive) { settings.resetPreferences() }
            }
            .onDisappear { app.player.applyPendingReload() }
        }
    }

    private func openCopiedLink() {
        let pasteboard = UIPasteboard.general
        let candidate = pasteboard.url ?? pasteboard.string.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let url = candidate, let host = url.host?.lowercased(), host.contains("youtube.com") || host == "youtu.be" {
            app.open(url: url)
        } else {
            app.show(Toast(icon: "exclamationmark.circle", text: "No YouTube link on the clipboard"))
        }
    }

    private var filterSummary: String {
        let n = filters.totalNetworkRules + filters.pageRules.cosmetic.count + filters.pageRules.scriptlets.count
        return n > 0 ? n.formatted(.number.notation(.compactName)) + " rules" : ""
    }

    private var customRuleCount: Int {
        filters.customFilters.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("!") }.count
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - Components

struct SettingLabel: View {
    let title: String
    let icon: String
    let color: Color
    var detail: String?

    init(_ title: String, icon: String, color: Color, detail: String? = nil) {
        self.title = title
        self.icon = icon
        self.color = color
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .foregroundStyle(Color.primary)
            if let detail, !detail.isEmpty {
                Spacer()
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatsHeader: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 0) {
            stat(value: settings.adsBlockedTotal.formatted(.number.notation(.compactName)), label: "Ads blocked", icon: "shield.lefthalf.filled")
            Divider().frame(height: 36)
            stat(value: settings.segmentsSkippedTotal.formatted(.number.notation(.compactName)), label: "Segments skipped", icon: "forward.end.alt")
            Divider().frame(height: 36)
            stat(value: timeSaved, label: "Time saved", icon: "clock")
        }
        .padding(.vertical, 16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.vertical, 6)
    }

    private var timeSaved: String {
        let s = settings.secondsSavedTotal
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private func stat(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SponsorCategoriesView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(SponsorCategory.all) { category in
                    Toggle(isOn: Binding(
                        get: { settings.sponsorCategories.contains(category.id) },
                        set: { on in
                            if on { settings.sponsorCategories.insert(category.id) } else { settings.sponsorCategories.remove(category.id) }
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                            if !category.detail.isEmpty {
                                Text(category.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Selected segments are skipped automatically. Use Undo on the notice to jump back.")
            }
        }
        .navigationTitle("Segments to Skip")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        List {
            ack("uBlock Origin filters", "Raymond Hill and contributors · GPLv3", "https://github.com/uBlockOrigin/uAssets")
            ack("EasyList and EasyPrivacy", "The EasyList authors · GPLv3 / CC BY-SA 3.0", "https://easylist.to")
            ack("Peter Lowe's list", "Peter Lowe", "https://pgl.yoyo.org/adservers/")
            ack("SponsorBlock", "Ajay Ramachandran and contributors · data under CC BY-NC-SA 4.0", "https://sponsor.ajay.app")
            Section {
                Text("Unreel is not affiliated with YouTube or Google. It reads YouTube's data and plays videos with YouTube's own web player, with ads removed, on your device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func ack(_ title: String, _ detail: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(Color.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
