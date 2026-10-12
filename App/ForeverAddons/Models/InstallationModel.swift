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
    var compatibleOnly = true
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
            managedIndex = Dictionary(
                addons.compactMap { if case .managed(let addon, _) = $0 { (addon.id.description.lowercased(), addon) } else { nil } },
                uniquingKeysWith: { first, _ in first })
            rebuildInstalledRows()
            rebuildBrowseRows()
        }
    }
    @ObservationIgnored private var addonIndex: [AddonStatus.ID: Int] = [:]
    /// Managed add-ons by lower-cased `AddonRef.description`: the one source of "is it
    /// installed" for Browse rows, the inspector and add-on windows. GitHub names are
    /// case-insensitive, and search results don't always match the stored case.
    @ObservationIgnored private var managedIndex: [String: InstalledAddon] = [:]
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var updateStates: [AddonRef: UpdateState] = [:] {
        didSet {
            rebuildInstalledRows()
            rebuildBrowseRows()
        }
    }
    /// While set, row rebuilds wait for `batchingRows` to finish and run once.
    @ObservationIgnored private var rowsBatched = false
    @ObservationIgnored private var rowsNeedRebuild = false
    /// Installed-table rebuilds so far, for tests.
    @ObservationIgnored private(set) var installedRowBuilds = 0
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
    /// The core's GitHub fallback (or an explicit live search) is in flight.
    private(set) var isSearchingGitHub = false
    /// The search stream sent its last update, so empty results really mean "no results".
    private(set) var isSearchComplete = false
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
    /// Fetched once per add-on per session, for the `detailsLimit` most recently viewed
    /// (each holds a parsed README); the core also caches them on disk.
    private(set) var details: [AddonRef: DetailsState] = [:]
    @ObservationIgnored private var detailsUse = RecentKeys<AddonRef>(limit: InstallationModel.detailsLimit)
    @ObservationIgnored private var detailLoads: [AddonRef: UUID] = [:]
    static let detailsLimit = 20

    // Live metadata
    /// Reads stored verdicts for rows the database reports as changed. Nil without a real manager.
    @ObservationIgnored private let supportReader: SupportCache?
    @ObservationIgnored private var changedRepos: Set<String> = []
    @ObservationIgnored private var needsBrowseReload = false
    @ObservationIgnored private var patchTask: Task<Void, Never>?
    @ObservationIgnored private var lastPatch: ContinuousClock.Instant?
    /// Database changes are applied at most this often; a refresh writes a verdict per repo.
    static let livePatchInterval: Duration = .milliseconds(500)

    init(installation: Installation, manager: any AddonManaging, reportError: @escaping @MainActor (String) -> Void) {
        self.installation = installation
        self.manager = manager
        self.reportError = reportError
        let database = (manager as? AddonManager)?.database
        self.supportReader = database.map { SupportCache(database: $0) }
        if let database { observeChanges(database) }
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

    /// The managed add-on for `ref`, compared case-insensitively.
    func addon(for ref: AddonRef) -> InstalledAddon? {
        managedIndex[ref.description.lowercased()]
    }

    /// The primary action for `ref` wherever it's shown: Browse rows, the inspector and the
    /// add-on window all ask this, so they can't disagree.
    func installAction(for ref: AddonRef) -> InstallAction {
        let addon = addon(for: ref)
        return InstallAction(installed: addon, update: addon.flatMap { updateStates[$0.id] })
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
        if case .available(let release) = updateStates[addon(for: ref)?.id ?? ref] { release } else { nil }
    }

    // MARK: Table rows

    /// Runs `body`, which may change several things the Installed rows depend on, with one
    /// rebuild (and one re-sort) at the end.
    private func batchingRows(_ body: () -> Void) {
        rowsBatched = true
        body()
        rowsBatched = false
        if rowsNeedRebuild { rebuildInstalledRows() }
    }

    private func rebuildInstalledRows() {
        if rowsBatched {
            rowsNeedRebuild = true
            return
        }
        rowsNeedRebuild = false
        installedRowBuilds += 1
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
        case .unmanaged(let unmanaged):
            return unmanaged.folders.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || unmanaged.title.localizedCaseInsensitiveContains(query)
        }
    }

    /// A Browse row for `result`, with its action from the managed list.
    func browseRow(for result: SearchResult, now: Date = .now) -> BrowseRow {
        BrowseRow(result, action: installAction(for: result.id), now: now)
    }

    private func rebuildBrowseRows() {
        let now = Date.now
        var results: [SearchResult]
        if browseOptions.query.isEmpty {
            let list = browseOptions.home == .popular ? browse?.popular : browse?.recent
            results = list ?? []
        } else {
            results = searchResults
        }
        // The home lists come back unfiltered, and live patches can turn a search result unsupported.
        results = results.filter { !browseOptions.compatibleOnly || !Self.hiddenByCompatibleOnly($0.support) }
        var rows = results.map { browseRow(for: $0, now: now) }
        if let sort = browseOptions.sort { rows.sort(using: sort) }
        guard rows != browseRows else { return }
        browseRows = rows
        browseRowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func hiddenByCompatibleOnly(_ status: SupportStatus) -> Bool {
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
        // Badges change live through `observeChanges`; the reload at the end picks up rows
        // that newly qualify for Popular or Recently Updated.
        for await progress in manager.refresh(in: installation, force: force) {
            refresh.progress = progress
            guard progress.phase == .finished else {
                didWork = true
                continue
            }
            if let updates = progress.updates { apply(updates) }
            lastChecked = await manager.lastRefresh(in: installation) ?? .now
        }
        if didWork, browse != nil { await loadBrowse() }
    }

    /// Reads when the last refresh finished, for "Last fetched" before this session refreshes.
    func loadLastRefresh() async {
        guard lastChecked == nil else { return }
        lastChecked = await manager.lastRefresh(in: installation)
    }

    /// Also used by tests to set update states without a refresh.
    func apply(_ updates: [AddonRef: UpdateState]) {
        if updates != updateStates { updateStates = updates }
        for (ref, state) in updates {
            let error: String? = if case .failed(let message) = state { message } else { nil }
            if row(ref.description).error != error { row(ref.description).error = error }
        }
    }

    func updateAll() async {
        await update(refsWithUpdates)
    }

    /// Installs the releases the last check found (`.available`), without resolving them
    /// again, and drives per-row progress. Refs without one are ignored. A failed row keeps
    /// its error; the rest continue.
    func update(_ refs: [AddonRef]) async {
        let releases = refs.compactMap(availableRelease(for:))
        guard !releases.isEmpty else { return }
        let refs = releases.map(\.ref)
        isUpdatingAll = true
        defer { isUpdatingAll = false }
        for ref in refs { row(ref.description).error = nil }
        for await event in updates(releases) { apply(event) }
        // Clear any rows the stream never finished (e.g. cancelled).
        for ref in refs where row(ref.description).activity != nil { row(ref.description).activity = nil }
        await reload()
    }

    func apply(_ event: OperationEvent) {
        switch event {
        case .queued(let ref):
            row(ref.description).activity = .queued
        case .downloading(let ref, let progress):
            row(ref.description).activity = .downloading(progress)
        case .installing(let ref):
            row(ref.description).activity = .installing
        case .done(let addon):
            row(addon.id.description).activity = nil
            // Both change the row; rebuild and re-sort the table once.
            batchingRows {
                updateStates[addon.id] = .upToDate
                replace(addon)
            }
        case .skipped(let ref, _):
            row(ref.description).activity = nil
        case .failed(let ref, let message):
            row(ref.description).activity = nil
            row(ref.description).error = message
        }
    }

    private func updates(_ releases: [ResolvedRelease]) -> AsyncStream<OperationEvent> {
        manager.update(releases: releases, in: installation)
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

    /// Returns true on success so the sheet can dismiss. With `release` (from a preview) it's
    /// installed as is; otherwise `ref` is resolved first.
    func adopt(folder: String, as ref: AddonRef, release: ResolvedRelease? = nil) async -> Bool {
        var succeeded = false
        await perform(AddonStatus.unmanagedID(folder), label: "Adopting…") {
            if let release, release.ref == ref {
                _ = try await self.manager.adopt(release, in: self.installation)
            } else {
                _ = try await self.manager.adopt(folder: folder, as: ref, in: self.installation)
            }
            succeeded = true
        }
        return succeeded
    }

    /// Resolves `ref`'s release for this flavor and lists the folders adopting it replaces.
    /// Reloads afterwards: the core now knows what the release ships, which can group rows.
    func adoptionPreview(for ref: AddonRef, folders: [String]) async -> AdoptionPreviewState {
        let state: AdoptionPreviewState
        do {
            state = .ready(try await manager.adoptionPreview(for: ref, folders: folders, in: installation))
        } catch AddonError.noCompatibleRelease {
            state = .noBuild
        } catch {
            state = .failed(error.localizedDescription)
        }
        if !Task.isCancelled { await reload() }
        return state
    }

    /// Moves unmanaged folders to the Trash; `id` is the row that shows progress and errors.
    /// Returns true on success.
    @discardableResult
    func removeUnmanaged(_ folders: [String], id: String) async -> Bool {
        var succeeded = false
        await perform(id, label: "Moving to Trash…") {
            try await self.manager.removeUnmanaged(folders: folders, from: self.installation)
            succeeded = true
        }
        return succeeded
    }

    /// An explicit live GitHub search, for the Adopt sheet. Spends one search request (of 10
    /// a minute) unless the answer is stored; never runs on its own.
    func searchGitHub(_ text: String) async -> [SearchResult] {
        let query = SearchQuery(text: text, flavor: installation.flavor, compatibleOnly: false, includeLiveGitHub: true)
        var last: [SearchResult] = []
        for await update in manager.searchUpdates(query, in: installation, installed: addons) {
            last = update.results
        }
        return last
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
    /// Passes the add-ons already loaded, so typing doesn't rescan `AddOns/`.
    func search(_ query: SearchQuery) async {
        isSearching = true
        isSearchingGitHub = false
        isSearchComplete = false
        defer {
            if !Task.isCancelled {
                isSearching = false
                isSearchingGitHub = false
            }
        }
        for await update in manager.searchUpdates(query, in: installation, installed: addons) {
            guard !Task.isCancelled else { return }
            if update.results != searchResults { searchResults = update.results }
            isSearchingGitHub = update.isSearchingGitHub
            isSearchComplete = update.isComplete
        }
    }

    func clearSearch() {
        if !searchResults.isEmpty { searchResults = [] }
        isSearching = false
        isSearchingGitHub = false
        isSearchComplete = false
    }

    /// Empty-query Browse content (docs/features/search.md): popular, recently updated and category chips.
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
        if case .loaded? = details[ref], !force {
            _ = detailsUse.use(ref)
            return
        }
        let token = UUID()
        detailLoads[ref] = token
        setDetails(.loading, for: ref)
        let outcome: DetailsState?
        do {
            let fetched = try await manager.details(for: ref, in: installation)
            let readme = fetched.readme ?? ""
            // Relative links in a README resolve against the repository.
            let base = fetched.repositoryURL.appending(path: "blob/HEAD/")
            let blocks = await Task.detached(priority: .userInitiated) { MarkdownParser.renderedBlocks(from: readme, baseURL: base) }.value
            outcome = Task.isCancelled ? nil : .loaded(fetched, readme: blocks)
        } catch {
            outcome = Task.isCancelled || error is CancellationError ? nil : .failed(error.localizedDescription)
        }
        guard detailLoads[ref] == token else { return }
        detailLoads[ref] = nil
        setDetails(outcome, for: ref)
        // Opening details refreshes that one repo in the core; show its fresh badge in the tables.
        if let support = outcome?.details?.support { applySupport([ref: support]) }
    }

    /// Fetches the latest release's notes (one GitHub API call unless stored) into the
    /// loaded details. Throws so the button can show what went wrong.
    func loadReleaseNotes(for ref: AddonRef) async throws {
        let notes = try await manager.releaseNotes(for: ref, in: installation)
        guard case .loaded(var loaded, let readme)? = details[ref] else { return }
        // No releases at all reads as "no notes", not as a failure.
        loaded.latestChangelog = notes?.markdown ?? ""
        if let notes {
            if loaded.latestVersion == nil { loaded.latestVersion = notes.version }
            loaded.latestPublishedAt = notes.publishedAt ?? loaded.latestPublishedAt
        }
        setDetails(.loaded(loaded, readme: readme), for: ref)
    }

    /// Stores `state` for `ref`, dropping the least recently viewed beyond `detailsLimit`.
    func setDetails(_ state: DetailsState?, for ref: AddonRef) {
        details[ref] = state
        guard state != nil else {
            detailsUse.remove(ref)
            return
        }
        for evicted in detailsUse.use(ref) { details[evicted] = nil }
    }

    private func applySupport(_ statuses: [AddonRef: SupportStatus]) {
        let results = searchResults.patchingSupport(statuses)
        if results != searchResults { searchResults = results }
        guard var content = browse else { return }
        content.popular = content.popular.patchingSupport(statuses)
        content.recent = content.recent.patchingSupport(statuses)
        if content.popular != browse?.popular || content.recent != browse?.recent { browse = content }
    }

    // MARK: Live metadata

    /// Follows the app's own database writes (refresh, details, live search) and patches the
    /// affected Browse rows. Writes by other processes are caught by `reloadMetadata`.
    private func observeChanges(_ database: MetadataDatabase) {
        Task { [weak self] in
            for await change in await database.changes() {
                guard let self else { return }
                self.receive(change)
            }
        }
    }

    private func receive(_ change: MetadataDatabase.Change) {
        let tables = change.tables
        guard !tables.isDisjoint(with: ["support", "repo_meta", "catalogue"]) else { return }
        if change.repos.isEmpty {
            needsBrowseReload = true
        } else {
            changedRepos.formUnion(change.repos)
            // Names, summaries and dates come from the catalogue; re-read the home lists if
            // one of their rows changed. Search results already carry fresh catalogue data.
            if tables.contains("catalogue"), !change.repos.isDisjoint(with: homeRepos) { needsBrowseReload = true }
        }
        schedulePatch()
    }

    private var homeRepos: Set<String> {
        Set(((browse?.popular ?? []) + (browse?.recent ?? [])).map { $0.id.identifier.lowercased() })
    }

    /// Applies pending changes now if the last patch was long enough ago, else when it is.
    private func schedulePatch() {
        guard patchTask == nil, needsBrowseReload || !changedRepos.isEmpty else { return }
        patchTask = Task { [weak self] in
            if let last = self?.lastPatch {
                try? await Task.sleep(until: last + Self.livePatchInterval, clock: .continuous)
            }
            guard let self else { return }
            self.lastPatch = .now
            let repos = self.changedRepos
            let reload = self.needsBrowseReload
            self.changedRepos = []
            self.needsBrowseReload = false
            if reload, self.browse != nil { await self.loadBrowse() }
            await self.patchSupport(for: repos)
            self.patchTask = nil
            // Changes that arrived while this one ran.
            self.schedulePatch()
        }
    }

    /// Re-reads the stored verdicts of visible rows in `repos` (lower-cased `owner/repo`).
    private func patchSupport(for repos: Set<String>) async {
        guard let supportReader, !repos.isEmpty else { return }
        let visible = Set((searchResults + (browse?.popular ?? []) + (browse?.recent ?? [])).map(\.id))
        var statuses: [AddonRef: SupportStatus] = [:]
        for ref in visible where repos.contains(ref.identifier.lowercased()) {
            statuses[ref] = await supportReader.status(for: ref, flavor: installation.flavor)
        }
        if !statuses.isEmpty { applySupport(statuses) }
    }

    /// Re-reads Browse after another process (`addonctl`) changed the metadata database.
    func reloadMetadata() async {
        if browse != nil { await loadBrowse() }
        await patchSupport(for: Set(searchResults.map { $0.id.identifier.lowercased() }))
    }
}

/// The Adopt sheet's check of the chosen repository.
enum AdoptionPreviewState: Equatable {
    case loading
    case ready(AdoptionPreview)
    /// No release has a build for the installation's flavor.
    case noBuild
    case failed(String)
}

enum DetailsState {
    case loading
    case loaded(AddonDetails, readme: [MarkdownBlock])
    case failed(String)

    var details: AddonDetails? {
        if case .loaded(let details, _) = self { details } else { nil }
    }
}
