import AddonKit
import Foundation
import Observation

/// What the Installed table shows. Set by the view; rows are rebuilt when it changes.
struct InstalledOptions: Equatable {
    var query = ""
    var section = LibrarySection.installed
    var sort = ColumnSort(InstalledColumn.name)
}

/// One installation's add-ons and their stored update states, and the Installed table's rows
/// for the selected library section, filtered and sorted, with each section's count. The one source of "is it
/// installed" for Browse rows, the inspector and add-on windows.
@Observable @MainActor
final class InstalledModel {
    let installation: Installation
    private let manager: any AddonManaging
    private let reportError: @MainActor (String) -> Void
    /// Called after every add-on reload; the app uses it to ignore its own store writes.
    @ObservationIgnored var didReload: (@MainActor () -> Void)?
    /// Called when the managed list or an update state changes, which Browse rows show.
    @ObservationIgnored var didChangeInstallState: (@MainActor () -> Void)?

    private(set) var addons: [AddonStatus] = [] {
        didSet {
            addonIndex = Dictionary(addons.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            managedIndex = Dictionary(
                addons.compactMap { if case .managed(let addon, _) = $0 { (addon.id.description.lowercased(), addon) } else { nil } },
                uniquingKeysWith: { first, _ in first })
            rebuildRows()
            didChangeInstallState?()
        }
    }
    @ObservationIgnored private var addonIndex: [AddonStatus.ID: Int] = [:]
    /// Managed add-ons by lower-cased `AddonRef.description`: the hashable form of
    /// `AddonRef.isSameRepo(as:)`, so lookups per row stay O(1).
    @ObservationIgnored private var managedIndex: [String: InstalledAddon] = [:]
    /// Required add-ons missing for the managed add-ons, from the core, reloaded with them.
    private(set) var missingDependencies: [MissingDependency] = [] {
        didSet {
            var index: [String: [MissingDependency]] = [:]
            for dependency in missingDependencies {
                for ref in dependency.requiredBy { index[ref.description.lowercased(), default: []].append(dependency) }
            }
            dependencyIndex = index
            rebuildRows()
        }
    }
    /// `missingDependencies` by requiring add-on, keyed like `managedIndex`.
    @ObservationIgnored private var dependencyIndex: [String: [MissingDependency]] = [:]
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// From the last check (`UpdateQueue`), and from the queue's own installs and pins.
    private(set) var updateStates: [AddonRef: UpdateState] = [:] {
        didSet {
            rebuildRows()
            didChangeInstallState?()
        }
    }

    /// While set, row rebuilds wait for `batchingRows` to finish and run once.
    @ObservationIgnored private var rowsBatched = false
    @ObservationIgnored private var rowsNeedRebuild = false
    /// Installed-table rebuilds so far, for tests.
    @ObservationIgnored private(set) var installedRowBuilds = 0

    var options = InstalledOptions() {
        didSet { if options != oldValue { rebuildRows() } }
    }
    /// The selected section's rows, filtered by the query and sorted.
    private(set) var rows: [InstalledRow] = []
    /// Rows per section before the query filter: the sidebar badges.
    private(set) var counts = LibraryCounts()

    init(installation: Installation, manager: any AddonManaging, reportError: @escaping @MainActor (String) -> Void) {
        self.installation = installation
        self.manager = manager
        self.reportError = reportError
    }

    // MARK: Lookups

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

    /// Required add-ons that `ref` needs and that aren't installed.
    func missingDependencies(for ref: AddonRef) -> [MissingDependency] {
        dependencyIndex[ref.description.lowercased()] ?? []
    }

    func status(id: AddonStatus.ID?) -> AddonStatus? {
        guard let id, let index = addonIndex[id], addons.indices.contains(index) else { return nil }
        return addons[index]
    }

    func availableRelease(for ref: AddonRef) -> ResolvedRelease? {
        if case .available(let release) = updateStates[addon(for: ref)?.id ?? ref] { release } else { nil }
    }

    var updateCount: Int { refsWithUpdates.count }

    /// Managed add-ons the core offers an update for (not pinned, an update stored): Update All.
    var refsWithUpdates: [AddonRef] {
        managed.filter { UpdateOffer(installed: $0, update: updateStates[$0.id], flavor: installation.flavor) != nil }.map(\.id)
    }

    /// The core's primary action for `ref` wherever it's shown: Browse rows, the inspector and
    /// the add-on window all ask this, so they can't disagree. `availableFlavors` decides
    /// whether a fallback build is offered when it isn't installed.
    func installAction(for ref: AddonRef, availableFlavors: Set<Flavor>?) -> InstallAction {
        let addon = addon(for: ref)
        return InstallAction(installed: addon, update: addon.flatMap { updateStates[$0.id] },
                             availableFlavors: availableFlavors, flavor: installation.flavor)
    }

    // MARK: Changes (from `UpdateQueue`)

    func setUpdateStates(_ updates: [AddonRef: UpdateState]) {
        if updates != updateStates { updateStates = updates }
    }

    func setUpdateState(_ state: UpdateState?, for ref: AddonRef) {
        updateStates[ref] = state
    }

    /// Swaps in a freshly installed record, keeping the row's missing-folder state.
    func replace(_ addon: InstalledAddon) {
        guard let index = addonIndex[addon.id.description], addons.indices.contains(index) else { return }
        if case .managed(_, let missing) = addons[index] {
            addons[index] = .managed(addon, missingFolders: missing)
        }
    }

    /// Runs `body`, which may change several things the rows depend on, with one rebuild
    /// (and one re-sort) at the end.
    func batchingRows(_ body: () -> Void) {
        rowsBatched = true
        body()
        rowsBatched = false
        if rowsNeedRebuild { rebuildRows() }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            let loaded = try await manager.addons(in: installation)
            // Local: the TOCs the reload just read. Always asked, since installing a missing
            // add-on by hand changes it without changing the managed list.
            let missing = await manager.missingDependencies(in: installation)
            // Unchanged reloads (e.g. after our own writes) don't touch the tables.
            batchingRows {
                if loaded != addons { addons = loaded }
                if missing != missingDependencies { missingDependencies = missing }
            }
            didReload?()
        } catch {
            reportError(error.localizedDescription)
        }
    }

    // MARK: Rows

    private func rebuildRows() {
        if rowsBatched {
            rowsNeedRebuild = true
            return
        }
        rowsNeedRebuild = false
        installedRowBuilds += 1
        let now = Date.now
        let query = options.query
        let all = addons.map { status in
            guard case .managed(let addon, _) = status else {
                return (status, InstalledRow(status: status, update: nil, flavor: installation.flavor, now: now))
            }
            let needs = dependencyIndex[addon.id.description.lowercased()]?.map(\.folder) ?? []
            return (status, InstalledRow(status: status, update: updateStates[addon.id], flavor: installation.flavor,
                                         missingDependencies: needs, now: now))
        }
        let counts = LibraryCounts(rows: all.map(\.1))
        var rows = all.filter { options.section.includes($0.1) && Self.matches($0.0, query: query) }.map(\.1)
        rows.sort(using: options.sort)
        if rows != self.rows { self.rows = rows }
        if counts != self.counts { self.counts = counts }
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
}
