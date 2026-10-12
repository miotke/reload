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

/// State and actions for one installation. Every action reports failures on the affected
/// row (`rowErrors`) and never throws to the UI.
@Observable @MainActor
final class InstallationModel {
    let installation: Installation
    private let manager: any AddonManaging
    private let reportError: @MainActor (String) -> Void

    // Installed tab
    private(set) var addons: [AddonStatus] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var updateStates: [AddonRef: UpdateState] = [:]
    private(set) var lastChecked: Date?
    /// Latest event of the running refresh; nil when none is running or it hasn't reported yet.
    private(set) var refreshProgress: RefreshProgress?
    private(set) var isRefreshing = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private(set) var isUpdatingAll = false
    /// Keyed by `AddonStatus.id` / `AddonRef.description`.
    private(set) var activity: [String: RowActivity] = [:]
    var rowErrors: [String: String] = [:]

    // Browse tab
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false
    /// The search stream has emitted its first (local) results.
    private(set) var hasLocalResults = false
    /// Popular / recently updated / categories for an empty query; nil until loaded.
    private(set) var browse: BrowseContent?
    /// Results that need `force` to overwrite an unmanaged folder.
    private(set) var needsOverwrite: Set<AddonRef> = []

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

    var managed: [InstalledAddon] {
        addons.compactMap { if case .managed(let addon, _) = $0 { addon } else { nil } }
    }

    var unmanaged: [AddonStatus] {
        addons.filter { if case .unmanaged = $0 { true } else { false } }
    }

    func addon(for ref: AddonRef) -> InstalledAddon? {
        managed.first { $0.id == ref }
    }

    func status(id: AddonStatus.ID?) -> AddonStatus? {
        guard let id else { return nil }
        return addons.first { $0.id == id }
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

    // MARK: Installed

    func reload() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            addons = try await manager.addons(in: installation)
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
            refreshProgress = nil
        }
        var didWork = false
        for await progress in manager.refresh(in: installation, force: force) {
            refreshProgress = progress
            guard progress.phase == .finished else {
                didWork = true
                continue
            }
            if let updates = progress.updates { apply(updates) }
            lastChecked = await manager.lastRefresh(in: installation) ?? .now
        }
        // Support checks may have changed the Browse badges.
        if didWork, browse != nil { await loadBrowse() }
    }

    private func apply(_ updates: [AddonRef: UpdateState]) {
        updateStates = updates
        for (ref, state) in updates {
            if case .failed(let message) = state { rowErrors[ref.description] = message }
            else { rowErrors[ref.description] = nil }
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
        for ref in refs { rowErrors[ref.description] = nil }
        for await event in manager.update(refs, in: installation) {
            switch event {
            case .queued(let ref):
                activity[ref.description] = .queued
            case .downloading(let ref, let progress):
                activity[ref.description] = .downloading(progress)
            case .installing(let ref):
                activity[ref.description] = .installing
            case .done(let addon):
                activity[addon.id.description] = nil
                updateStates[addon.id] = .upToDate
                replace(addon)
            case .skipped(let ref, _):
                activity[ref.description] = nil
            case .failed(let ref, let message):
                activity[ref.description] = nil
                rowErrors[ref.description] = message
            }
        }
        // Clear any rows the stream never finished (e.g. cancelled).
        for ref in refs where activity[ref.description] != nil { activity[ref.description] = nil }
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
        rowErrors[id] = nil
        if let label { activity[id] = .working(label) }
        do {
            try await body()
        } catch {
            rowErrors[id] = error.localizedDescription
        }
        activity[id] = nil
        await reload()
    }

    private func replace(_ addon: InstalledAddon) {
        guard let index = addons.firstIndex(where: { $0.id == addon.id.description }) else { return }
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
        searchResults = []
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
        let id = ref.description
        rowErrors[id] = nil
        needsOverwrite.remove(ref)
        activity[id] = .downloading(0)
        // Progress arrives on arbitrary threads; funnel it through a stream (newest value
        // wins) so the row is updated on the main actor and nothing lands after we finish.
        let (progress, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task { @MainActor in
            for await fraction in progress {
                activity[id] = fraction < 1 ? .downloading(fraction) : .installing
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
        activity[id] = nil

        switch result {
        case .success(let addon):
            markInstalled(addon)
            await reload()
        case .failure(let error):
            if case .unmanagedFolderExists = error as? AddonError { needsOverwrite.insert(ref) }
            rowErrors[id] = error.localizedDescription
        }
    }

    /// A result shown in Browse (search, popular or recent), for the inspector's header.
    func result(for ref: AddonRef) -> SearchResult? {
        searchResults.first { $0.id == ref }
            ?? browse?.popular.first { $0.id == ref }
            ?? browse?.recent.first { $0.id == ref }
    }

    private func markInstalled(_ addon: InstalledAddon) {
        for index in searchResults.indices where searchResults[index].id == addon.id {
            searchResults[index].installed = addon
            searchResults[index].origin.insert(.installed)
        }
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
        for index in searchResults.indices where searchResults[index].id == ref {
            searchResults[index].support = support
        }
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
