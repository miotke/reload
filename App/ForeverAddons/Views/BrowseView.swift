import AddonKit
import SwiftUI

/// Which list the Browse tab shows with an empty query.
enum BrowseHome: String, CaseIterable, Identifiable {
    case popular, recent
    var id: Self { self }

    var title: String {
        switch self {
        case .popular: "Popular"
        case .recent: "Recently Updated"
        }
    }
}

/// Search and browse add-ons (docs/design.md §7, §8).
///
/// One sortable table. With an empty query it lists Popular or Recently Updated (a switch in
/// the filter bar); with a query, or a category chip, it lists search results. Without a
/// chosen sort, rows keep the core's order: relevance for searches, stars or date for home.
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    var state: InstallationModel

    @AppStorage("browseForeverOnly") private var foreverOnly = true
    @AppStorage("browseHome") private var home: BrowseHome = .popular
    @AppStorage("browseSort") private var sortStorage = ""
    @SceneStorage("browseColumns") private var columns = TableColumnCustomization<SearchResult>()
    @State private var includeLiveGitHub = false

    private struct QueryKey: Hashable {
        var text: String
        var foreverOnly: Bool
        var includeLiveGitHub: Bool
        var installationID: String
    }

    private var trimmedQuery: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isHome: Bool { trimmedQuery.isEmpty }
    private var sort: ColumnSort<BrowseColumn>? { ColumnSort(storageValue: sortStorage) }

    private var sortOrder: Binding<[ColumnSort<BrowseColumn>]> {
        Binding(
            get: { sort.map { [$0] } ?? [] },
            set: { sortStorage = $0.first?.storageValue ?? "" })
    }

    private var rows: [SearchResult] {
        let base: [SearchResult]
        if isHome {
            let list = home == .popular ? state.browse?.popular : state.browse?.recent
            // Search applies Forever only in the core; the home lists come back unfiltered.
            base = (list ?? []).filter { !foreverOnly || !Self.hiddenByForeverOnly($0.support) }
        } else {
            base = state.searchResults
        }
        guard let sort else { return base }
        return base.sorted(using: sort)
    }

    var body: some View {
        @Bindable var model = model
        let rows = rows
        VStack(spacing: 0) {
            filterBar
            Divider()
            BrowseTable(state: state, rows: rows, selection: $model.selectedBrowseRef,
                        sortOrder: sortOrder, columns: $columns)
                .overlay { emptyState(rows) }
            Divider()
            statusBar(count: rows.count)
        }
        // `.task(id:)` cancels the previous search whenever the query changes; the sleep is the debounce.
        .task(id: QueryKey(text: trimmedQuery, foreverOnly: foreverOnly, includeLiveGitHub: includeLiveGitHub,
                           installationID: state.installation.id)) {
            let text = trimmedQuery
            guard !text.isEmpty else {
                state.clearSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await state.search(SearchQuery(text: text, flavor: state.installation.flavor,
                                           foreverOnly: foreverOnly, includeLiveGitHub: includeLiveGitHub))
        }
        .task(id: state.installation.id) {
            await state.loadBrowse()
        }
        .onChange(of: model.searchText) { includeLiveGitHub = false }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            if isHome {
                Picker("Show", selection: $home) {
                    ForEach(BrowseHome.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.browse?.categories ?? SearchAliases.categories) { category in
                        let selected = trimmedQuery.caseInsensitiveCompare(category.query) == .orderedSame
                        Button {
                            model.searchText = selected ? "" : category.query
                        } label: {
                            Label(category.title, systemImage: category.symbol)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(selected ? Color.accentColor : nil)
                        .controlSize(.small)
                    }
                }
            }
            Toggle("Forever only", isOn: $foreverOnly)
                .toggleStyle(.checkbox)
                .help("Hide add-ons verified not to support Forever. Unchecked add-ons are shown dimmed.")
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusBar(count: Int) -> some View {
        HStack(spacing: 8) {
            if !isHome && state.isSearching {
                ProgressView().controlSize(.mini)
                Text(state.isSearchingGitHub(query: trimmedQuery) ? "Searching GitHub…" : "Searching…")
            } else {
                Text(count == 1 ? "1 add-on" : "\(count) add-ons")
            }
            if sort != nil {
                Button(isHome ? "Default Order" : "Sort by Relevance") { sortStorage = "" }
                    .buttonStyle(.link)
                    .help("Go back to the order ForeverAddons suggests")
            }
            Spacer()
            if !isHome {
                Button("Search GitHub for More Results", systemImage: "magnifyingglass") {
                    includeLiveGitHub = true
                }
                .buttonStyle(.borderless)
                .disabled(includeLiveGitHub)
                .help("Runs a live GitHub search. Limited to a few searches per minute without a token.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private func emptyState(_ rows: [SearchResult]) -> some View {
        if rows.isEmpty {
            if isHome {
                if state.browse == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Nothing to Browse Yet", systemImage: "magnifyingglass",
                        description: Text("Search for an add-on by name, or pick a category above."))
                }
            } else if state.isSearching {
                // "No results" waits for the stream to finish: the core may still be asking GitHub.
                if state.isSearchingGitHub(query: trimmedQuery) {
                    ProgressView("Searching GitHub…").controlSize(.small).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } else {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
    }

    static func hiddenByForeverOnly(_ status: SupportStatus) -> Bool {
        switch status {
        case .unsupported, .noReleases: true
        default: false
        }
    }
}

private struct BrowseTable: View {
    @Environment(AppModel.self) private var model
    var state: InstallationModel
    var rows: [SearchResult]
    @Binding var selection: AddonRef?
    @Binding var sortOrder: [ColumnSort<BrowseColumn>]
    @Binding var columns: TableColumnCustomization<SearchResult>

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Name", sortUsing: ColumnSort(BrowseColumn.name)) { result in
                BrowseNameCell(result: result)
            }
            .width(min: 180, ideal: 320)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Forever", sortUsing: ColumnSort(BrowseColumn.support)) { result in
                SupportBadge(status: result.support)
            }
            .width(min: 84, ideal: 96, max: 130)
            .customizationID("forever")

            TableColumn("Stars", sortUsing: ColumnSort(BrowseColumn.stars, order: .reverse)) { result in
                Text(result.stars.map { $0.formatted() } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 64, max: 90)
            .customizationID("stars")

            TableColumn("Updated", sortUsing: ColumnSort(BrowseColumn.updated, order: .reverse)) { result in
                Text(result.lastUpdated.map { DayLabel.string(for: $0) } ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(result.lastUpdated?.formatted(date: .long, time: .shortened) ?? "Unknown")
            }
            .width(min: 80, ideal: 100, max: 140)
            .customizationID("updated")

            TableColumn("") { result in
                BrowseActionCell(state: state, result: result)
            }
            .width(min: 96, ideal: 110, max: 160)
            .customizationID("action")
            .disabledCustomizationBehavior(.visibility)
        }
        .contextMenu(forSelectionType: AddonRef.self) { refs in
            if let ref = refs.first {
                Button("Show Details") {
                    selection = ref
                    model.showInspector = true
                }
                if let url = ref.webURL {
                    Link("Open on \(ref.sourceName)", destination: url)
                }
            }
        } primaryAction: { refs in
            if let ref = refs.first {
                selection = ref
                model.showInspector = true
            }
        }
    }
}

private struct BrowseNameCell: View {
    var result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(result.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                Text("by \(result.owner)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if result.origin.contains(.github) {
                    Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
                        .help("Found by live GitHub search")
                }
            }
            Text(result.summary ?? "No description")
                .font(.caption)
                .foregroundStyle(result.summary == nil ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .opacity(SupportBadge.isDimmed(result.support) && result.installed == nil ? 0.6 : 1)
        .help(result.summary ?? result.name)
    }
}

private struct BrowseActionCell: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    var state: InstallationModel
    var result: SearchResult

    private var id: String { result.id.description }

    var body: some View {
        HStack(spacing: 6) {
            if let error = state.rowErrors[id] {
                RowErrorIcon(message: error)
            }
            if let installed = result.installed {
                Button("Open") { model.reveal(installed.id) }
                    .help("Show in the Installed tab")
            } else if let activity = state.activity[id] {
                ActivityIndicator(activity: activity, showsLabel: false)
            } else if state.needsOverwrite.contains(result.id) {
                Button("Overwrite", role: .destructive) {
                    Task { await state.install(result.id, channel: defaultChannel, force: true) }
                }
                .help("Replace the existing unmanaged folder")
            } else {
                Button("Install") {
                    Task { await state.install(result.id, channel: defaultChannel) }
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
