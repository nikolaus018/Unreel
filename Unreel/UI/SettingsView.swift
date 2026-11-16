import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var filters: FilterListManager
    @EnvironmentObject private var app: AppModel
    @State private var confirmReset = false
    @State private var confirmClearCache = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.adBlocking) {
                    SettingLabel("Block Ads", icon: "shield.lefthalf.filled", color: .red)
                }
                NavigationLink {
                    FilterListsView()
                } label: {
                    SettingLabel("Filter Lists", icon: "list.bullet.rectangle", color: .orange, detail: filterSummary)
                }
                .disabled(!settings.adBlocking)
                Toggle(isOn: $settings.hideShorts) {
                    SettingLabel("Hide Shorts", icon: "rectangle.slash", color: .pink)
                }
            } header: {
                Text("Content")
            } footer: {
                Text("Ads are removed from YouTube's data before the player sees them, and filter lists from uBlock Origin and EasyList block ad and tracking requests. Hidden Shorts are left out of every feed, search and channel; links to Shorts still open in the regular player.")
            }

            Section {
                Toggle(isOn: $settings.sponsorBlock.animation()) {
                    SettingLabel("Skip Sponsored Segments", icon: "forward.end.alt", color: .green)
                }
                if settings.sponsorBlock {
                    NavigationLink {
                        SponsorCategoriesView()
                    } label: {
                        SettingLabel("Segments to Skip", icon: "checklist", color: .teal, detail: "\(settings.sponsorCategories.count)")
                    }
                    Toggle(isOn: $settings.sponsorNotice) {
                        SettingLabel("Show Skip Notice", icon: "text.bubble", color: .mint)
                    }
                }
            } header: {
                Text("SponsorBlock")
            } footer: {
                Text("Segments are submitted by the SponsorBlock community. Only the first characters of a hash of the video ID are sent.")
            }

            Section {
                Picker(selection: $settings.defaultSpeed) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { s in
                        Text(s == 1 ? "Normal" : String(format: "%g×", s)).tag(s)
                    }
                } label: {
                    SettingLabel("Default Speed", icon: "gauge.with.dots.needle.67percent", color: .orange)
                }
                Picker(selection: $settings.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Preferred Quality", icon: "sparkles.tv", color: .cyan)
                }
                Toggle(isOn: $settings.autoplayNext) {
                    SettingLabel("Autoplay", icon: "play.circle", color: .red)
                }
                Toggle(isOn: $settings.backgroundPlay) {
                    SettingLabel("Background Playback", icon: "headphones", color: .indigo)
                }
                Toggle(isOn: $settings.autoPiP) {
                    SettingLabel("Start PiP Automatically", icon: "pip", color: .blue)
                }
                Toggle(isOn: $settings.lockScreenControls) {
                    SettingLabel("Lock Screen Controls", icon: "lock.rectangle.on.rectangle", color: .gray)
                }
                Toggle(isOn: $settings.keepScreenOn) {
                    SettingLabel("Keep Screen On", icon: "sun.max", color: .yellow)
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Picture in Picture starts when you leave the app while a video plays. Keep Screen On only applies while a video is playing.")
            }

            Section("Watch Page") {
                Toggle(isOn: $settings.hideComments) { SettingLabel("Hide Comments", icon: "text.bubble", color: .blue) }
                Toggle(isOn: $settings.hideRelated) { SettingLabel("Hide Up Next", icon: "square.stack", color: .gray) }
            }

            Section("General") {
                Picker(selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Appearance", icon: "circle.lefthalf.filled", color: .indigo)
                }
                Picker(selection: $settings.startPage) {
                    ForEach(StartPage.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Open On", icon: "house", color: .red)
                }
                Toggle(isOn: $settings.haptics) { SettingLabel("Haptics", icon: "waveform", color: .pink) }
            }

            Section {
                Toggle(isOn: $settings.listScriptlets) {
                    SettingLabel("Filter-List Scriptlets", icon: "curlybraces", color: .purple)
                }
                NavigationLink {
                    CustomFiltersView()
                } label: {
                    SettingLabel("My Filters", icon: "pencil.and.list.clipboard", color: .orange,
                                 detail: filters.customFilters.isEmpty ? "None" : "\(customRuleCount)")
                }
                Button { confirmClearCache = true } label: {
                    SettingLabel("Clear Cache", icon: "internaldrive", color: .gray)
                }
                Button { confirmReset = true } label: {
                    SettingLabel("Reset All Settings", icon: "arrow.counterclockwise", color: .red, destructive: true)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Scriptlets let filter lists fix ads that network rules can't block. Clearing the cache keeps your sign-in.")
            }

            Section {
                LabeledContent("Version", value: appVersion)
                Link(destination: URL(string: "https://github.com/nikolaus018/Unreel")!) {
                    SettingLabel("Source Code", icon: "chevron.left.forwardslash.chevron.right", color: .gray, external: true)
                }
                NavigationLink { AcknowledgementsView() } label: {
                    SettingLabel("Acknowledgements", icon: "heart", color: .pink)
                }
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset All Settings", role: .destructive) {
                settings.resetPreferences()
                app.show(Toast(icon: "arrow.counterclockwise", text: "Settings reset"))
            }
        } message: {
            Text("Your sign-in, filter lists and statistics are kept.")
        }
        .confirmationDialog("Clear the cache?", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) { Task { await app.clearCache() } }
        } message: {
            Text("Thumbnails and pages are downloaded again as you browse.")
        }
        .onDisappear { app.player.applyPendingReload() }
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

/// A Settings-app style row label: a tinted icon tile, the title and an optional value.
struct SettingLabel: View {
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 29
    let title: String
    let icon: String
    let color: Color
    var detail: String?
    var destructive = false
    var external = false

    init(_ title: String, icon: String, color: Color, detail: String? = nil, destructive: Bool = false, external: Bool = false) {
        self.title = title
        self.icon = icon
        self.color = color
        self.detail = detail
        self.destructive = destructive
        self.external = external
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: tile * 0.24, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(destructive ? Color.red : Color.primary)
            if (detail?.isEmpty == false) || external {
                Spacer(minLength: 8)
            }
            if let detail, !detail.isEmpty {
                Text(detail).foregroundStyle(.secondary)
            }
            if external {
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Lifetime blocking statistics, shown at the top of the You tab.
struct StatsCard: View {
    @EnvironmentObject private var settings: AppSettings
    @ScaledMetric(relativeTo: .footnote) private var iconHeight: CGFloat = 18

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { stats(divided: true) }
            VStack(alignment: .leading, spacing: 12) { stats(divided: false) }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stats(divided: Bool) -> some View {
        stat(value: settings.adsBlockedTotal.formatted(.number.notation(.compactName)), label: "Ads Blocked",
             icon: "shield.lefthalf.filled", color: .red)
        if divided { Divider().frame(height: 40) }
        stat(value: settings.segmentsSkippedTotal.formatted(.number.notation(.compactName)), label: "Segments Skipped",
             icon: "forward.end.alt", color: .green)
        if divided { Divider().frame(height: 40) }
        stat(value: timeSaved, label: "Time Saved", icon: "clock", color: .blue)
    }

    private var timeSaved: String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = settings.secondsSavedTotal < 3600 ? [.minutes, .seconds] : [.hours, .minutes]
        return Duration.seconds(settings.secondsSavedTotal).formatted(.units(allowed: units, width: .narrow, maximumUnitCount: 2))
    }

    private func stat(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
                .frame(height: iconHeight)
                .accessibilityHidden(true)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
