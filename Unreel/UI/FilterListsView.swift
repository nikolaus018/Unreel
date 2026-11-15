import SwiftUI

struct FilterListsView: View {
    @EnvironmentObject private var filters: FilterListManager
    @EnvironmentObject private var app: AppModel
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        statusIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusTitle).font(.headline)
                            Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if case .downloading(let done, let total) = filters.phase {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                    } else if filters.phase == .compiling {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                .padding(.vertical, 4)

                Button {
                    Task {
                        await filters.updateAll()
                        if let message = filters.lastMessage { app.show(Toast(icon: "checkmark.shield.fill", text: message)) }
                        app.player.applyPendingReload()
                    }
                } label: {
                    Label("Update Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(filters.phase.isBusy)

                Picker("Update automatically", selection: $filters.updateInterval) {
                    ForEach(UpdateInterval.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Lists are checked when the app opens. Rule counts only include rules that can apply on YouTube.")
            }

            Section("Lists") {
                ForEach(FilterCatalog.lists) { list in
                    Toggle(isOn: binding(for: list.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(list.name)
                            Text(list.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(detail(for: list.id))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(filters.states[list.id]?.lastError != nil ? Color.red : Color.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .disabled(filters.phase.isBusy)
                }
            }

            Section {
                NavigationLink("My Filters") { CustomFiltersView() }
            }

            Section {
                Button("Reset Filter Lists", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Deletes downloaded lists and goes back to the snapshot included with the app, then rebuilds.")
            }
        }
        .navigationTitle("Filter Lists")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset filter lists?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { Task { await filters.resetToDefaults() } }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { filters.enabledIDs.contains(id) },
            set: { on in if on { filters.enabledIDs.insert(id) } else { filters.enabledIDs.remove(id) } })
    }

    private var statusIcon: some View {
        Group {
            switch filters.phase {
            case .idle:
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            case .downloading:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            case .compiling:
                Image(systemName: "gearshape.2.fill").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 30))
        .symbolEffect(.pulse, isActive: filters.phase.isBusy)
    }

    private var statusTitle: String {
        switch filters.phase {
        case .idle: "Protection active"
        case .downloading(let done, let total): "Downloading \(done) of \(total)…"
        case .compiling: "Compiling rules…"
        }
    }

    private var statusDetail: String {
        let rules = filters.totalNetworkRules.formatted() + " network · " + filters.pageRules.cosmetic.count.formatted() + " cosmetic · "
            + filters.pageRules.scriptlets.count.formatted() + " scriptlets"
        if let date = filters.lastBuild {
            return rules + "\nBuilt " + date.formatted(.relative(presentation: .named))
        }
        return rules
    }

    private func detail(for id: String) -> String {
        guard filters.enabledIDs.contains(id) else { return "Off" }
        let state = filters.states[id]
        if let error = state?.lastError { return "Update failed: \(error)" }
        var parts: [String] = []
        if let s = state, s.networkRules + s.cosmeticRules + s.scriptletRules > 0 {
            parts.append("\((s.networkRules + s.cosmeticRules + s.scriptletRules).formatted()) rules")
        }
        if let date = state?.lastUpdated {
            parts.append("updated " + date.formatted(.relative(presentation: .named)))
        } else if filters.isBundledOnly(id) {
            parts.append("built-in snapshot")
        } else {
            parts.append("not downloaded yet")
        }
        return parts.joined(separator: " · ")
    }
}

struct CustomFiltersView: View {
    @EnvironmentObject private var filters: FilterListManager
    @EnvironmentObject private var app: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(.background.secondary)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("""
                        ! One rule per line, uBlock Origin syntax
                        m.youtube.com##ytm-rich-section-renderer
                        ||example.com^
                        youtube.com##+js(set, ytInitialPlayerResponse.adSlots, undefined)
                        """)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(17)
                        .allowsHitTesting(false)
                    }
                }
        }
        .navigationTitle("My Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    focused = false
                    filters.customFilters = text
                    Task {
                        await filters.applyCustomFilters()
                        app.player.applyPendingReload()
                        app.show(Toast(icon: "checkmark.circle.fill", text: "Filters applied"))
                    }
                }
                .disabled(text == filters.customFilters || filters.phase.isBusy)
            }
        }
        .onAppear { text = filters.customFilters }
    }
}
