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
    var model: AppModel
    var state: InstallationModel

    @AppStorage("browseForeverOnly") private var compatibleOnly = true
    @AppStorage("browseHome") private var home: BrowseHome = .popular
    @AppStorage("browseSort") private var sortStorage = ""
    @SceneStorage("browseColumns") private var columns = TableColumnCustomization<BrowseRow>()
    @State private var includeLiveGitHub = false

    private struct QueryKey: Hashable {
        var text: String
        var compatibleOnly: Bool
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

    /// Filtering and sorting happen in the model, once per change, not in `body`.
    private var options: BrowseOptions {
        BrowseOptions(query: trimmedQuery, home: home, compatibleOnly: compatibleOnly, sort: sort)
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            filterBar
            Divider()
            BrowseTable(model: model, state: state, selection: $model.selectedBrowseID, sortOrder: sortOrder, columns: $columns)
                .overlay { emptyState }
            Divider()
            statusBar
        }
        .onChange(of: options, initial: true) { state.browseOptions = options }
        // `.task(id:)` cancels the previous search whenever the query changes; the sleep is the debounce.
        .task(id: QueryKey(text: trimmedQuery, compatibleOnly: compatibleOnly, includeLiveGitHub: includeLiveGitHub,
                           installationID: state.installation.id)) {
            let text = trimmedQuery
            guard !text.isEmpty else {
                state.clearSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await state.search(SearchQuery(text: text, flavor: state.installation.flavor,
                                           compatibleOnly: compatibleOnly, includeLiveGitHub: includeLiveGitHub))
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
            Toggle("\(state.installation.flavor.displayName) only", isOn: $compatibleOnly)
                .toggleStyle(.checkbox)
                .help("Hide add-ons verified not to support \(state.installation.flavor.displayName). Unchecked add-ons are shown dimmed.")
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        let count = state.browseRows.count
        return HStack(spacing: 8) {
            if !isHome && state.isSearching && !state.isSearchComplete {
                ProgressView().controlSize(.mini)
                Text(state.isSearchingGitHub ? "Searching GitHub…" : "Searching…")
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
                .help("Runs a deeper live GitHub search. Limited to a few searches per minute without a token.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var emptyState: some View {
        if state.browseRows.isEmpty {
            if isHome {
                if state.browse == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Nothing to Browse Yet", systemImage: "magnifyingglass",
                        description: Text("Search for an add-on by name, or pick a category above."))
                }
            } else if state.isSearchComplete {
                ContentUnavailableView.search(text: trimmedQuery)
            } else if state.isSearchingGitHub {
                ProgressView("Searching GitHub…").controlSize(.small).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }
}

private struct BrowseTable: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var state: InstallationModel
    @Binding var selection: BrowseRow.ID?
    @Binding var sortOrder: [ColumnSort<BrowseColumn>]
    @Binding var columns: TableColumnCustomization<BrowseRow>

    var body: some View {
        Table(state.browseRows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Name", sortUsing: ColumnSort(BrowseColumn.name)) { row in
                BrowseNameCell(row: row)
            }
            .width(min: 180, ideal: 320)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(state.installation.flavor.displayName, sortUsing: ColumnSort(BrowseColumn.support)) { row in
                SupportBadge(status: row.support, flavor: state.installation.flavor)
            }
            .width(min: 84, ideal: 96, max: 130)
            .customizationID("forever")

            TableColumn("Stars", sortUsing: ColumnSort(BrowseColumn.stars, order: .reverse)) { row in
                Text(row.starsText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 64, max: 90)
            .customizationID("stars")

            TableColumn("Updated", sortUsing: ColumnSort(BrowseColumn.updated, order: .reverse)) { row in
                Text(row.updatedText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 100, max: 140)
            .customizationID("updated")

            TableColumn("") { row in
                BrowseActionCell(model: model, state: state, row: row, rowState: state.row(row.id))
            }
            .width(min: 96, ideal: 110, max: 160)
            .customizationID("action")
            .disabledCustomizationBehavior(.visibility)
        }
        .contextMenu(forSelectionType: BrowseRow.ID.self) { ids in
            if let id = ids.first, let ref = AddonRef(rowID: id) {
                Button("Show Details") {
                    selection = id
                    model.showInspector = true
                }
                Button("Open in New Window") { openWindow(id: AddonWindowID.sceneID, value: windowID(ref)) }
                if let url = ref.webURL {
                    Link("Open on \(ref.sourceName)", destination: url)
                }
            }
        } primaryAction: { ids in
            // Double-click or Return.
            if let id = ids.first, let ref = AddonRef(rowID: id) {
                openWindow(id: AddonWindowID.sceneID, value: windowID(ref))
            }
        }
    }

    private func windowID(_ ref: AddonRef) -> AddonWindowID {
        AddonWindowID(ref: ref, installationID: state.installation.id)
    }
}

private struct BrowseNameCell: View {
    var row: BrowseRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(row.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                Text("by \(row.owner)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if row.isFromGitHub {
                    Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
                        .help("Found by live GitHub search")
                }
            }
            Text(row.summary ?? "No description")
                .font(.caption)
                .foregroundStyle(row.summary == nil ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .opacity(SupportBadge.isDimmed(row.support) && !row.isInstalled ? 0.6 : 1)
        .help(row.summary ?? row.name)
    }
}

private struct BrowseActionCell: View {
    var model: AppModel
    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    var state: InstallationModel
    var row: BrowseRow
    var rowState: RowState

    var body: some View {
        HStack(spacing: 6) {
            if let error = rowState.error {
                RowErrorIcon(message: error)
            }
            if row.isInstalled {
                Button("Open") { model.reveal(row.ref) }
                    .help("Show in the Installed tab")
            } else if let activity = rowState.activity {
                ActivityIndicator(activity: activity, showsLabel: false)
            } else if rowState.needsOverwrite {
                Button("Overwrite", role: .destructive) {
                    Task { await state.install(row.ref, channel: defaultChannel, force: true) }
                }
                .help("Replace the existing unmanaged folder")
            } else {
                Button("Install") {
                    Task { await state.install(row.ref, channel: defaultChannel) }
                }
            }
        }
        // Table cells otherwise draw buttons borderless, which reads as plain text.
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

