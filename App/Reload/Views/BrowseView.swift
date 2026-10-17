import AddonKit
import SwiftUI

/// Search and browse add-ons (docs/app/layout.md).
///
/// One sortable table. With an empty query it lists Popular or Recently Updated (a switch in
/// the filter bar); with a query, or a category from the sidebar, it lists search results.
/// Without a chosen sort, rows keep the core's order: relevance for searches, stars or date
/// for home.
struct BrowseView: View {
    var model: AppModel
    var browse: BrowseModel
    var queue: UpdateQueue
    var inspector: InspectorModel
    /// The catalogue query: the toolbar search, within the category's own query when one is selected.
    var query: String
    var category: SearchCategory?

    @AppStorage(SettingsKey.showOtherGames) private var showsOtherGames = false
    @AppStorage("browseHome") private var home: BrowseHome = .popular
    @AppStorage("browseSort") private var sortStorage = ""
    @SceneStorage("browseColumns") private var columns = TableColumnCustomization<BrowseRow>()
    @State private var includeLiveGitHub = false

    private struct QueryKey: Hashable {
        var text: String
        var showsOtherGames: Bool
        var includeLiveGitHub: Bool
        var installationID: String
        var sources: Set<SourceID>
        var catalogueVersion: Int
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isHome: Bool { trimmedQuery.isEmpty }
    private var sort: ColumnSort<BrowseColumn>? { ColumnSort(storageValue: sortStorage) }

    private var sortOrder: Binding<[ColumnSort<BrowseColumn>]> {
        Binding(
            get: { sort.map { [$0] } ?? [] },
            set: { sortStorage = $0.first?.storageValue ?? "" })
    }

    /// Filtering and sorting happen in the model, once per change, not in `body`.
    private var options: BrowseOptions {
        BrowseOptions(query: trimmedQuery, home: home, showsOtherGames: showsOtherGames, sort: sort)
    }

    var body: some View {
        @Bindable var inspector = inspector
        VStack(spacing: 0) {
            BrowseFilterBar(isHome: isHome, category: category, home: $home)
            Divider()
            BrowseTable(model: model, browse: browse, queue: queue, selection: $inspector.selectedBrowseID,
                        sortOrder: sortOrder, columns: $columns)
                .overlay { emptyState }
            Divider()
            BrowseStatusBar(browse: browse, isHome: isHome, hasSort: sort != nil,
                            includeLiveGitHub: $includeLiveGitHub, resetSort: { sortStorage = "" })
        }
        .onChange(of: options, initial: true) { browse.options = options }
        // `.task(id:)` cancels the previous search whenever the query changes; the sleep is the debounce.
        .task(id: QueryKey(text: trimmedQuery, showsOtherGames: showsOtherGames, includeLiveGitHub: includeLiveGitHub,
                           installationID: browse.installation.id, sources: model.enabledSources,
                           catalogueVersion: browse.catalogueVersion)) {
            let text = trimmedQuery
            guard !text.isEmpty else {
                browse.clearSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await browse.search(SearchQuery(text: text, flavor: browse.installation.flavor,
                                            hideIncompatible: !showsOtherGames, includeLiveGitHub: includeLiveGitHub))
        }
        .task(id: browse.installation.id) {
            await queue.loadLastRefresh()
            await browse.loadBrowse()
        }
        .onChange(of: trimmedQuery) { includeLiveGitHub = false }
    }

    @ViewBuilder private var emptyState: some View {
        if browse.rows.isEmpty {
            if isHome {
                if browse.content == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Nothing to Browse Yet", systemImage: "magnifyingglass",
                        description: Text("Search for an add-on by name, or pick a category in the sidebar."))
                }
            } else if browse.isSearchComplete {
                ContentUnavailableView.search(text: trimmedQuery)
            } else if browse.isSearchingGitHub {
                ProgressView("Searching GitHub…").controlSize(.small).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }
}

/// Popular / Recently Updated with an empty query, or the selected category. Which games show
/// is a setting, not a picker: the window's installation already names the game.
struct BrowseFilterBar: View {
    var isHome: Bool
    var category: SearchCategory?
    @Binding var home: BrowseHome

    var body: some View {
        HStack(spacing: 12) {
            if isHome {
                Picker("Show", selection: $home) {
                    ForEach(BrowseHome.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            } else if let category {
                Label(category.title, systemImage: category.symbol)
                    .font(.headline)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The count or search progress, the games legend and the deeper GitHub search
/// (docs/app/layout.md#browse-table). "Last fetched" lives in the sidebar's footer.
struct BrowseStatusBar: View {
    var browse: BrowseModel
    var isHome: Bool
    var hasSort: Bool
    @Binding var includeLiveGitHub: Bool
    var resetSort: () -> Void

    var body: some View {
        let count = browse.rows.count
        HStack(spacing: 8) {
            if !isHome && browse.isSearching && !browse.isSearchComplete {
                ProgressView().controlSize(.mini)
                Text(browse.isSearchingGitHub ? "Searching GitHub…" : "Searching…")
            } else {
                Text(count == 1 ? "1 add-on" : "\(count) add-ons")
            }
            Text("·")
            GameLegend(flavor: browse.installation.flavor)
            if hasSort {
                Button(isHome ? "Default Order" : "Sort by Relevance", action: resetSort)
                    .buttonStyle(.link)
                    .help("Go back to the order Reload suggests")
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
}

private struct BrowseTable: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var browse: BrowseModel
    var queue: UpdateQueue
    @Binding var selection: BrowseRow.ID?
    @Binding var sortOrder: [ColumnSort<BrowseColumn>]
    @Binding var columns: TableColumnCustomization<BrowseRow>

    var body: some View {
        Table(browse.rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Name", sortUsing: ColumnSort(BrowseColumn.name)) { row in
                BrowseNameCell(browse: browse, row: row)
            }
            .width(min: 180, ideal: 320)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Games", sortUsing: ColumnSort(BrowseColumn.games)) { row in
                GameBubbles(model: row.games)
            }
            .width(min: 66, ideal: 70, max: 100)
            .customizationID("forever")

            TableColumn("Stars", sortUsing: ColumnSort(BrowseColumn.stars, order: .reverse)) { row in
                BrowseStarsCell(row: row)
            }
            .width(min: 50, ideal: 64, max: 90)
            .customizationID("stars")
            // Empty for most rows; turned on from the header's context menu.
            .defaultVisibility(.hidden)

            TableColumn("Last updated", sortUsing: ColumnSort(BrowseColumn.updated, order: .reverse)) { row in
                BrowseUpdatedCell(row: row)
            }
            .width(min: 80, ideal: 100, max: 140)
            .customizationID("updated")

            TableColumn("") { row in
                BrowseActionCell(queue: queue, row: row, rowState: queue.row(row.id))
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
                if let installed = browse.row(id: id)?.action.installedRef {
                    Button("Show in Installed") { model.reveal(installed) }
                }
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
        AddonWindowID(ref: ref, installationID: browse.installation.id)
    }
}

// MARK: - Cells

struct BrowseNameCell: View {
    var browse: BrowseModel
    var row: BrowseRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(row.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                if let byline = row.byline {
                    Text(byline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if row.isFromGitHub {
                    Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
                        .help("Found by live GitHub search")
                }
            }
            // A dimmed row is already faint, so its placeholder stays secondary to remain readable.
            Text(row.summary ?? "No description")
                .font(.caption)
                .foregroundStyle(row.summary == nil && !row.isDimmed ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .opacity(row.isDimmed && !row.isInstalled ? 0.6 : 1)
        .help(row.summary ?? row.name)
        // The table only hosts cells for rows on screen (plus a few around them), so these
        // track what the user is looking at for the visible-row checks. The Name column can't
        // be hidden, so every visible row reports.
        .onAppear { browse.rowAppeared(row.id) }
        .onDisappear { browse.rowDisappeared(row.id) }
    }
}

struct BrowseStarsCell: View {
    var row: BrowseRow

    var body: some View {
        Text(row.starsText)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct BrowseUpdatedCell: View {
    var row: BrowseRow

    var body: some View {
        Text(row.updatedText)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct BrowseActionCell: View {
    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    var queue: UpdateQueue
    var row: BrowseRow
    var rowState: RowState

    var body: some View {
        HStack(spacing: 6) {
            if let error = rowState.error {
                RowErrorIcon(message: error)
            }
            if let activity = rowState.activity ?? row.action.installedRef.flatMap({ queue.row($0.description).activity }) {
                ActivityIndicator(activity: activity, showsLabel: false)
            } else if case .update(let ref, let version, let offer) = row.action {
                Button("Update") { Task { await queue.update([ref]) } }
                    .help("Update \(version) to \(offer.label)")
                    .disabled(queue.isUpdatingAll)
            } else if case .installed(_, let version) = row.action {
                Label("Installed", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .help("\(version) is installed. Double-click to open it.")
            } else if rowState.needsOverwrite {
                Button("Overwrite", role: .destructive) {
                    Task { await queue.install(row.ref, channel: defaultChannel, force: true) }
                }
                .help("Replace the existing unmanaged folder")
            } else {
                // The fallback build needs the inspector's confirmation, so Browse installs only
                // the installation's own build.
                Button("Install") {
                    Task { await queue.install(row.ref, channel: defaultChannel) }
                }
            }
        }
        // Table cells otherwise draw buttons borderless, which reads as plain text.
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
