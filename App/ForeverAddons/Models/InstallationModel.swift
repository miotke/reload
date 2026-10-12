import AddonKit
import Foundation
import Observation

/// Progress of a long-running operation on one row.
enum RowActivity: Equatable {
    case queued
    case downloading(Double)
    case installing
    /// Generic in-flight work (rollback, uninstall, adopt…).
    case working(String)

    var label: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        case .working(let label): label
        }
    }

    var fraction: Double? {
        if case .downloading(let value) = self { value } else { nil }
    }
}

/// Per-row progress and errors. One object per row, so a download progress tick re-renders
/// only the cells (and inspector controls) that read that row, not every row in the table.
@Observable @MainActor
final class RowState {
    var activity: RowActivity?
    var error: String?
    /// An install failed because an unmanaged folder is in the way; retry needs `force`.
    var needsOverwrite = false
}

/// Progress of the running refresh, kept apart from `InstallationModel` so only the sidebar
/// bar and the first-launch sheet re-render on each progress event.
@Observable @MainActor
final class RefreshStatus {
    /// Latest event; nil when no refresh is running or it hasn't reported yet.
    fileprivate(set) var progress: RefreshProgress?

    /// For the sidebar: throttled refreshes that finish at once never report a phase, so
    /// they don't flash the bar.
    var visibleProgress: RefreshProgress? {
        guard let progress, progress.phase != .finished else { return nil }
        return progress
    }
}

/// What the Browse table shows. Set by the view; rows are rebuilt when it changes.
struct BrowseOptions: Equatable {
    var query = ""
    var home: BrowseHome = .popular
    var foreverOnly = true
    var sort: ColumnSort<BrowseColumn>?
}

/// What the Installed table shows. Set by the view; rows are rebuilt when it changes.
struct InstalledOptions: Equatable {
    var query = ""
    var sort = ColumnSort(InstalledColumn.name)
}

/// State and actions for one installation. Every action reports failures on the affected
/// row (`row(_:).error`) and never throws to the UI.
@Observable @MainActor
final class InstallationModel {
    let installation: Installation
    private let manager: any AddonManaging
    private let reportError: @MainActor (String) -> Void
    /// Called after every add-on reload; the app uses it to ignore its own store writes.
    @ObservationIgnored var didReload: (@MainActor () -> Void)?

    // Installed tab
    private(set) var addons: [AddonStatus] = [] {
        didSet {
            addonIndex = Dictionary(addons.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            rebuildInstalledRows()
        }
    }
    @ObservationIgnored private var addonIndex: [AddonStatus.ID: Int] = [:]
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var updateStates: [AddonRef: UpdateState] = [:] {
        didSet { rebuildInstalledRows() }
    }
    private(set) var lastChecked: Date?
    let refresh = RefreshStatus()
    private(set) var isRefreshing = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private(set) var isUpdatingAll = false
    @ObservationIgnored private var rowStates: [String: RowState] = [:]

    var installedOptions = InstalledOptions() {
        didSet { if installedOptions != oldValue { rebuildInstalledRows() } }
    }
    /// Filtered and sorted; managed and unmanaged rows are separate table sections.
    private(set) var managedRows: [InstalledRow] = []
    private(set) var unmanagedRows: [InstalledRow] = []

    // Browse tab
    private(set) var searchResults: [SearchResult] = [] {
        didSet { rebuildBrowseRows() }
    }
    private(set) var isSearching = false
    /// The search stream has emitted its first (local) results.
    private(set) var hasLocalResults = false
    /// Popular / recently updated / categories for an empty query; nil until loaded.
    private(set) var browse: BrowseContent? {
        didSet { rebuildBrowseRows() }
    }
    var browseOptions = BrowseOptions() {
        didSet { if browseOptions != oldValue { rebuildBrowseRows() } }
    }
    private(set) var browseRows: [BrowseRow] = []
    @ObservationIgnored private var browseRowIndex: [BrowseRow.ID: Int] = [:]

    // Inspector
    /// Fetched once per add-on per session; the core also caches them on disk.
    private(set) var details: [AddonRef: DetailsState] = [:]
    @ObservationIgnored private var detailLoads: [AddonRef: UUID] = [:]

    init(installation: Installation, manager: any AddonManaging, reportError: @escaping @MainActor (String) -> Void) {
        self.installation = installation
        self.manager = manager
        self.reportError = reportError
    }

    // MARK: Derived

    /// The state object for a row, created on first use. Keyed by `AddonStatus.id` / `AddonRef.description`.
    func row(_ id: String) -> RowState {
        if let existing = rowStates[id] { return existing }
        let state = RowState()
        rowStates[id] = state
        return state
    }

    var managed: [InstalledAddon] {
        addons.compactMap { if case .managed(let addon, _) = $0 { addon } else { nil } }
    }

    var unmanaged: [AddonStatus] {
        addons.filter { if case .unmanaged = $0 { true } else { false } }
    }

    func addon(for ref: AddonRef) -> InstalledAddon? {
        if case .managed(let addon, _)? = status(id: ref.description) { addon } else { nil }
    }

    func status(id: AddonStatus.ID?) -> AddonStatus? {
        guard let id, let index = addonIndex[id], addons.indices.contains(index) else { return nil }
        return addons[index]
    }

    func browseRow(id: BrowseRow.ID) -> BrowseRow? {
        guard let index = browseRowIndex[id], browseRows.indices.contains(index) else { return nil }
        return browseRows[index]
    }

    var refsWithUpdates: [AddonRef] {
        managed.filter { addon in
            guard !addon.pinned, case .available = updateStates[addon.id] else { return false }
            return true
        }.map(\.id)
    }

    var updateCount: Int { refsWithUpdates.count }

    func availableRelease(for ref: AddonRef) -> ResolvedRelease? {
        if case .available(let release) = updateStates[ref] { release } else { nil }
    }

    // MARK: Table rows

    private func rebuildInstalledRows() {
        let now = Date.now
        let query = installedOptions.query
        var rows = addons.compactMap { status -> InstalledRow? in
            guard Self.matches(status, query: query) else { return nil }
            let update: UpdateState? = if case .managed(let addon, _) = status { updateStates[addon.id] } else { nil }
            return InstalledRow(status: status, update: update, now: now)
        }
        rows.sort(using: installedOptions.sort)
        let managed = rows.filter(\.isManaged)
        let unmanaged = rows.filter { !$0.isManaged }
        if managed != managedRows { managedRows = managed }
        if unmanaged != unmanagedRows { unmanagedRows = unmanaged }
    }

    private static func matches(_ status: AddonStatus, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        switch status {
        case .managed(let addon, _):
            return addon.name.localizedCaseInsensitiveContains(query)
                || addon.id.identifier.localizedCaseInsensitiveContains(query)
                || addon.folders.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        case .unmanaged(let folder, let toc, _):
            return folder.localizedCaseInsensitiveContains(query)
                || (toc?.title?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func rebuildBrowseRows() {
        let now = Date.now
        let results: [SearchResult]
        if browseOptions.query.isEmpty {
            let list = browseOptions.home == .popular ? browse?.popular : browse?.recent
            // Search applies Forever only in the core; the home lists come back unfiltered.
            results = (list ?? []).filter { !browseOptions.foreverOnly || !Self.hiddenByForeverOnly($0.support) }
        } else {
            results = searchResults
        }
        var rows = results.map { BrowseRow($0, now: now) }
        if let sort = browseOptions.sort { rows.sort(using: sort) }
        guard rows != browseRows else { return }
        browseRows = rows
        browseRowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func hiddenByForeverOnly(_ status: SupportStatus) -> Bool {
        switch status {
        case .unsupported, .noReleases: true
        default: false
        }
    }

    // MARK: Installed

    func reload() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            let loaded = try await manager.addons(in: installation)
            // Unchanged reloads (e.g. after our own writes) don't touch the tables.
            if loaded != addons { addons = loaded }
            didReload?()
        } catch {
            reportError(error.localizedDescription)
        }
    }

    /// Starts a metadata refresh (catalogue, update checks, Forever support) unless one is
    /// already running, and returns the running task. Owned by the model, not a view, so it
    /// keeps going when the first-launch sheet is sent to the background.
    @discardableResult
    func startRefresh(force: Bool) -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        isRefreshing = true
        let task = Task { await runRefresh(force: force) }
        refreshTask = task
        return task
    }

    private func runRefresh(force: Bool) async {
        defer {
            refreshTask = nil
            isRefreshing = false
            refresh.progress = nil
        }
        var didWork = false
        var lastBrowseReload = ContinuousClock.now
        for await progress in manager.refresh(in: installation, force: force) {
            refresh.progress = progress
            guard progress.phase == .finished else {
                didWork = true
                // Support checks change Browse badges as they go; pick them up now and then.
                if progress.phase == .support, browse != nil, ContinuousClock.now - lastBrowseReload > .seconds(2) {
                    lastBrowseReload = .now
                    await loadBrowse()
                }
                continue
            }
            if let updates = progress.updates { apply(updates) }
            lastChecked = await manager.lastRefresh(in: installation) ?? .now
        }
        if didWork, browse != nil { await loadBrowse() }
    }

    private func apply(_ updates: [AddonRef: UpdateState]) {
        if updates != updateStates { updateStates = updates }
        for (ref, state) in updates {
            let error: String? = if case .failed(let message) = state { message } else { nil }
            if row(ref.description).error != error { row(ref.description).error = error }
        }
    }

    func updateAll() async {
        await update(refsWithUpdates)
    }

    /// Runs updates and drives per-row progress. A failed row keeps its error; the rest continue.
    func update(_ refs: [AddonRef]) async {
        guard !refs.isEmpty else { return }
        isUpdatingAll = true
        defer { isUpdatingAll = false }
        for ref in refs { row(ref.description).error = nil }
        for await event in manager.update(refs, in: installation) {
            switch event {
            case .queued(let ref):
                row(ref.description).activity = .queued
            case .downloading(let ref, let progress):
                row(ref.description).activity = .downloading(progress)
            case .installing(let ref):
                row(ref.description).activity = .installing
            case .done(let addon):
                row(addon.id.description).activity = nil
                updateStates[addon.id] = .upToDate
                replace(addon)
            case .skipped(let ref, _):
                row(ref.description).activity = nil
            case .failed(let ref, let message):
                row(ref.description).activity = nil
                row(ref.description).error = message
            }
        }
        // Clear any rows the stream never finished (e.g. cancelled).
        for ref in refs where row(ref.description).activity != nil { row(ref.description).activity = nil }
        await reload()
    }

    func uninstall(_ ref: AddonRef) async {
        await perform(ref.description, label: "Uninstalling…") {
            try await self.manager.uninstall(ref, from: self.installation)
            self.updateStates[ref] = nil
        }
    }

    func rollback(_ ref: AddonRef) async {
        await perform(ref.description, label: "Rolling back…") {
            try await self.manager.rollback(ref, in: self.installation)
            // Rollback pins the add-on, so there's nothing to check.
            self.updateStates[ref] = .pinned
        }
    }

    func setPinned(_ pinned: Bool, for ref: AddonRef) async {
        await perform(ref.description, label: nil) {
            try await self.manager.setPinned(pinned, for: ref, in: self.installation)
            if pinned { self.updateStates[ref] = .pinned } else if self.updateStates[ref] == .pinned { self.updateStates[ref] = nil }
        }
    }

    func setChannel(_ channel: Channel, for ref: AddonRef) async {
        await perform(ref.description, label: nil) {
            try await self.manager.setChannel(channel, for: ref, in: self.installation)
            self.updateStates[ref] = nil
        }
    }

    /// Returns true on success so the sheet can dismiss.
    func adopt(folder: String, as ref: AddonRef) async -> Bool {
        let id = "unmanaged:\(folder)"
        var succeeded = false
        await perform(id, label: "Adopting…") {
            _ = try await self.manager.adopt(folder: folder, as: ref, in: self.installation)
            succeeded = true
        }
        return succeeded
    }

    /// Runs `body`, shows `label` on the row meanwhile, records failures on the row, then reloads.
    private func perform(_ id: String, label: String?, _ body: @MainActor () async throws -> Void) async {
        let row = row(id)
        row.error = nil
        if let label { row.activity = .working(label) }
        do {
            try await body()
        } catch {
            row.error = error.localizedDescription
        }
        row.activity = nil
        await reload()
    }

    private func replace(_ addon: InstalledAddon) {
        guard let index = addonIndex[addon.id.description], addons.indices.contains(index) else { return }
        if case .managed(_, let missing) = addons[index] {
            addons[index] = .managed(addon, missingFolders: missing)
        }
    }

    // MARK: Browse

    /// Consumes the search stream until it finishes or the calling task is cancelled.
    func search(_ query: SearchQuery) async {
        isSearching = true
        hasLocalResults = false
        defer { if !Task.isCancelled { isSearching = false } }
        for await results in manager.search(query, in: installation) {
            guard !Task.isCancelled else { return }
            searchResults = results
            hasLocalResults = true
        }
    }

    func clearSearch() {
        if !searchResults.isEmpty { searchResults = [] }
        isSearching = false
        hasLocalResults = false
    }

    /// The local results are in but the stream is still open: with few matches for a query
    /// of 3+ characters, the core is falling back to a live GitHub search.
    func isSearchingGitHub(query: String) -> Bool {
        isSearching && hasLocalResults && query.count >= 3 && searchResults.count < 3
    }

    /// Empty-query Browse content (§7.5): popular, recently updated and category chips.
    func loadBrowse() async {
        var content = await manager.browse(in: installation)
        guard !Task.isCancelled else { return }
        // Browse lists come from the catalogue; mark what's already installed here.
        for index in content.popular.indices { content.popular[index].installed = addon(for: content.popular[index].id) }
        for index in content.recent.indices { content.recent[index].installed = addon(for: content.recent[index].id) }
        browse = content
    }

    /// Installs `ref`, showing download progress on its row, then the installing phase.
    func install(_ ref: AddonRef, channel: Channel, force: Bool = false) async {
        let row = row(ref.description)
        row.error = nil
        row.needsOverwrite = false
        row.activity = .downloading(0)
        // Progress arrives on arbitrary threads; funnel it through a stream (newest value
        // wins) so the row is updated on the main actor and nothing lands after we finish.
        let (progress, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task { @MainActor in
            for await fraction in progress {
                row.activity = fraction < 1 ? .downloading(fraction) : .installing
            }
        }
        let result: Result<InstalledAddon, any Error>
        do {
            result = .success(try await manager.install(ref, into: installation, channel: channel, force: force) { fraction in
                continuation.yield(fraction)
            })
        } catch {
            result = .failure(error)
        }
        continuation.finish()
        await progressTask.value
        row.activity = nil

        switch result {
        case .success(let addon):
            markInstalled(addon)
            await reload()
        case .failure(let error):
            if case .unmanagedFolderExists = error as? AddonError { row.needsOverwrite = true }
            row.error = error.localizedDescription
        }
    }

    private func markInstalled(_ addon: InstalledAddon) {
        var results = searchResults
        for index in results.indices where results[index].id == addon.id {
            results[index].installed = addon
            results[index].origin.insert(.installed)
        }
        if results != searchResults { searchResults = results }
        guard var content = browse else { return }
        for index in content.popular.indices where content.popular[index].id == addon.id {
            content.popular[index].installed = addon
        }
        for index in content.recent.indices where content.recent[index].id == addon.id {
            content.recent[index].installed = addon
        }
        browse = content
    }

    // MARK: Details

    /// Fetches details unless they're already loaded. Runs in the caller's task, so the
    /// inspector cancels it when the selection changes; a cancelled load leaves no state
    /// behind, and only the newest load for a ref may write its result.
    func loadDetails(for ref: AddonRef, force: Bool = false) async {
        if case .loaded? = details[ref], !force { return }
        let token = UUID()
        detailLoads[ref] = token
        details[ref] = .loading
        let outcome: DetailsState?
        do {
            let fetched = try await manager.details(for: ref, in: installation)
            let readme = fetched.readme ?? ""
            let blocks = await Task.detached(priority: .userInitiated) { MarkdownParser.blocks(from: readme) }.value
            outcome = Task.isCancelled ? nil : .loaded(fetched, readme: blocks)
        } catch {
            outcome = Task.isCancelled || error is CancellationError ? nil : .failed(error.localizedDescription)
        }
        guard detailLoads[ref] == token else { return }
        detailLoads[ref] = nil
        details[ref] = outcome
        // Opening details refreshes that one repo in the core; show its fresh badge in the tables.
        if let support = outcome?.details?.support { applySupport(support, to: ref) }
    }

    private func applySupport(_ support: SupportStatus, to ref: AddonRef) {
        var results = searchResults
        for index in results.indices where results[index].id == ref { results[index].support = support }
        if results != searchResults { searchResults = results }
        guard var content = browse else { return }
        for index in content.popular.indices where content.popular[index].id == ref { content.popular[index].support = support }
        for index in content.recent.indices where content.recent[index].id == ref { content.recent[index].support = support }
        if content.popular != browse?.popular || content.recent != browse?.recent { browse = content }
    }
}

enum DetailsState {
    case loading
    case loaded(AddonDetails, readme: [MarkdownBlock])
    case failed(String)

    var details: AddonDetails? {
        if case .loaded(let details, _) = self { details } else { nil }
    }
}
