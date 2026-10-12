import AddonKit
import Foundation
import Observation

/// What the Browse table shows. Set by the view; rows are rebuilt when it changes.
struct BrowseOptions: Equatable {
    var query = ""
    var home: BrowseHome = .popular
    var hideIncompatible = true
    var sort: ColumnSort<BrowseColumn>?
}

/// The Browse tab of one installation: the search stream, the empty-query home lists, the
/// sorted and filtered rows, visible-row checks, and live patches from the metadata database
/// (docs/app/live-data.md). Installed state comes from `InstalledModel`, never from results.
@Observable @MainActor
final class BrowseModel {
    let installation: Installation
    private let manager: any AddonManaging
    private let installed: InstalledModel
    /// Visible-row checks wait while a refresh runs: it's checking the same repos.
    @ObservationIgnored var isRefreshing: @MainActor () -> Bool = { false }

    private(set) var searchResults: [SearchResult] = [] {
        didSet { rebuildRows() }
    }
    private(set) var isSearching = false
    /// The core's GitHub fallback (or an explicit live search) is in flight.
    private(set) var isSearchingGitHub = false
    /// The search stream sent its last update, so empty results really mean "no results".
    private(set) var isSearchComplete = false
    /// Popular / recently updated / categories for an empty query; nil until loaded.
    private(set) var content: BrowseContent? {
        didSet { rebuildRows() }
    }
    var options = BrowseOptions() {
        didSet { if options != oldValue { rebuildRows() } }
    }
    private(set) var rows: [BrowseRow] = []
    @ObservationIgnored private var rowIndex: [BrowseRow.ID: Int] = [:]

    /// Rows whose cells are on screen, by row ID; not observed, so scrolling re-renders nothing.
    @ObservationIgnored private var visibleRowIDs: Set<BrowseRow.ID> = []
    @ObservationIgnored private var visibleCheckTask: Task<Void, Never>?
    /// How long scrolling must pause before the rows on screen are checked.
    static let visibleCheckDelay: Duration = .seconds(1)

    /// Patches rows from the app's own metadata writes. Set once in `init`.
    @ObservationIgnored private var live: LiveMetadata?

    init(installation: Installation, manager: any AddonManaging, installed: InstalledModel) {
        self.installation = installation
        self.manager = manager
        self.installed = installed
        live = LiveMetadata(browse: self, manager: manager)
    }

    // MARK: Rows

    func row(id: BrowseRow.ID) -> BrowseRow? {
        guard let index = rowIndex[id], rows.indices.contains(index) else { return nil }
        return rows[index]
    }

    /// A Browse row for `result`, with its action from the managed list.
    func row(for result: SearchResult, now: Date = .now) -> BrowseRow {
        BrowseRow(result, flavor: installation.flavor,
                  action: installed.installAction(for: result.id, availableFlavors: result.availableFlavors), now: now)
    }

    /// Also called when the managed list or an update state changes.
    func rebuildRows() {
        let now = Date.now
        var results: [SearchResult]
        if options.query.isEmpty {
            let list = options.home == .popular ? content?.popular : content?.recent
            results = list ?? []
        } else {
            results = searchResults
        }
        // The home lists come back unfiltered, and live patches can fill in a search result's games.
        if options.hideIncompatible {
            let flavor = installation.flavor
            results = results.filter { !BrowseFilter.isHidden($0, for: flavor, isInstalled: installed.addon(for: $0.id) != nil) }
        }
        var rows = results.map { row(for: $0, now: now) }
        if let sort = options.sort { rows.sort(using: sort) }
        guard rows != self.rows else { return }
        self.rows = rows
        rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Search and home lists

    /// Consumes the search stream until it finishes or the calling task is cancelled.
    /// Passes the add-ons already loaded, so typing doesn't rescan `AddOns/`.
    func search(_ query: SearchQuery) async {
        cancelVisibleCheck()
        isSearching = true
        isSearchingGitHub = false
        isSearchComplete = false
        defer {
            if !Task.isCancelled {
                isSearching = false
                isSearchingGitHub = false
            }
        }
        for await update in manager.searchUpdates(query, in: installation, installed: installed.addons) {
            guard !Task.isCancelled else { return }
            if update.results != searchResults { searchResults = update.results }
            isSearchingGitHub = update.isSearchingGitHub
            isSearchComplete = update.isComplete
        }
    }

    func clearSearch() {
        cancelVisibleCheck()
        if !searchResults.isEmpty { searchResults = [] }
        isSearching = false
        isSearchingGitHub = false
        isSearchComplete = false
    }

    /// An explicit live GitHub search, for the Adopt sheet. Spends one search request (of 10
    /// a minute) unless the answer is stored; never runs on its own.
    func searchGitHub(_ text: String) async -> [SearchResult] {
        let query = SearchQuery(text: text, flavor: installation.flavor, hideIncompatible: false, includeLiveGitHub: true)
        var last: [SearchResult] = []
        for await update in manager.searchUpdates(query, in: installation, installed: installed.addons) {
            last = update.results
        }
        return last
    }

    /// Empty-query Browse content (docs/features/search.md): popular, recently updated and category chips.
    func loadBrowse() async {
        var content = await manager.browse(in: installation)
        guard !Task.isCancelled else { return }
        // Browse lists come from the catalogue; mark what's already installed here.
        for index in content.popular.indices { content.popular[index].installed = installed.addon(for: content.popular[index].id) }
        for index in content.recent.indices { content.recent[index].installed = installed.addon(for: content.recent[index].id) }
        self.content = content
    }

    func markInstalled(_ addon: InstalledAddon) {
        var results = searchResults
        for index in results.indices where results[index].id == addon.id {
            results[index].installed = addon
            results[index].origin.insert(.installed)
        }
        if results != searchResults { searchResults = results }
        guard var content else { return }
        for index in content.popular.indices where content.popular[index].id == addon.id {
            content.popular[index].installed = addon
        }
        for index in content.recent.indices where content.recent[index].id == addon.id {
            content.recent[index].installed = addon
        }
        self.content = content
    }

    /// Replaces the games and verdicts of listed rows; a database change touches only its own rows.
    func applyStored(_ answers: [AddonRef: StoredAvailability]) {
        let results = searchResults.patching(answers)
        if results != searchResults { searchResults = results }
        guard var content else { return }
        content.popular = content.popular.patching(answers)
        content.recent = content.recent.patching(answers)
        if content.popular != self.content?.popular || content.recent != self.content?.recent { self.content = content }
    }

    /// Every result currently listed: search results and both home lists.
    var listedRefs: Set<AddonRef> {
        Set((searchResults + (content?.popular ?? []) + (content?.recent ?? [])).map(\.id))
    }

    /// Re-reads Browse after another process (`reload`) changed the metadata database.
    func reloadMetadata() async {
        if content != nil { await loadBrowse() }
        await live?.patchSupport(for: Set(searchResults.map { $0.id.identifier.lowercased() }))
    }

    // MARK: Visible rows

    /// A Browse cell came on screen. Each change restarts the settle timer.
    func rowAppeared(_ id: BrowseRow.ID) {
        visibleRowIDs.insert(id)
        scheduleVisibleCheck()
    }

    func rowDisappeared(_ id: BrowseRow.ID) {
        visibleRowIDs.remove(id)
    }

    /// Checks the rows on screen once scrolling has paused for `visibleCheckDelay`.
    private func scheduleVisibleCheck() {
        visibleCheckTask?.cancel()
        visibleCheckTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleCheckDelay)
            guard !Task.isCancelled, let self else { return }
            await self.checkVisibleRows()
        }
    }

    func cancelVisibleCheck() {
        visibleCheckTask?.cancel()
        visibleCheckTask = nil
    }

    /// The rows on screen, unchecked ones first; the core skips those with a fresh answer.
    /// Nothing while a refresh runs: it's checking the same repos.
    func checkVisibleRows() async {
        guard !isRefreshing() else { return }
        let refs = Self.visibleCheckTargets(rows: rows, visible: visibleRowIDs)
        guard !refs.isEmpty else { return }
        await manager.checkVisible(refs, in: installation)
    }

    /// The rows on screen, in table order, ordered and capped by the core.
    nonisolated static func visibleCheckTargets(rows: [BrowseRow], visible: Set<BrowseRow.ID>) -> [AddonRef] {
        let onScreen = rows.filter { visible.contains($0.id) }
        let checked = Set(onScreen.filter(\.games.isChecked).map(\.ref))
        return BrowseFilter.visibleCheckTargets(onScreen.map(\.ref), isChecked: checked.contains)
    }
}
