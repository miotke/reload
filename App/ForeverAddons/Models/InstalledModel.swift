import AddonKit
import Foundation
import Observation

/// What the Installed table shows. Set by the view; rows are rebuilt when it changes.
struct InstalledOptions: Equatable {
    var query = ""
    var sort = ColumnSort(InstalledColumn.name)
}

/// One installation's add-ons and their stored update states, and the Installed table's rows:
/// managed and unmanaged sections, each filtered and sorted. The one source of "is it
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
    /// Managed add-ons by lower-cased `AddonRef.description`. GitHub names are
    /// case-insensitive, and search results don't always match the stored case.
    @ObservationIgnored private var managedIndex: [String: InstalledAddon] = [:]
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
    /// Filtered and sorted; managed and unmanaged rows are separate table sections.
    private(set) var managedRows: [InstalledRow] = []
    private(set) var unmanagedRows: [InstalledRow] = []

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

    func status(id: AddonStatus.ID?) -> AddonStatus? {
        guard let id, let index = addonIndex[id], addons.indices.contains(index) else { return nil }
        return addons[index]
    }

    func availableRelease(for ref: AddonRef) -> ResolvedRelease? {
        if case .available(let release) = updateStates[addon(for: ref)?.id ?? ref] { release } else { nil }
    }

    var updateCount: Int { refsWithUpdates.count }

    // Decision logic: moves to core.
    // TODO(core-ui): which add-ons Update All installs (not pinned, an update stored) belongs
    // to the core; the app should only ask for the list.
    var refsWithUpdates: [AddonRef] {
        managed.filter { addon in
            guard !addon.pinned, case .available = updateStates[addon.id] else { return false }
            return true
        }.map(\.id)
    }

    // Decision logic: moves to core.
    // TODO(core-ui): the core should report the install action (install / installed / update,
    // and whether the update replaces a Retail build), so Browse, the inspector and the
    // add-on window only display it.
    /// The primary action for `ref` wherever it's shown: Browse rows, the inspector and the
    /// add-on window all ask this, so they can't disagree.
    func installAction(for ref: AddonRef) -> InstallAction {
        let addon = addon(for: ref)
        let update = addon.flatMap { updateStates[$0.id] }
        var action = InstallAction(installed: addon, update: update)
        // A Retail build being replaced by the installation's own reads "Update to Forever build".
        if case .update(let ref, let version, _) = action, let addon,
           case .available(let release)? = update, RetailBuildOffer.replacesFallbackBuild(addon, with: release) {
            action = .update(ref: ref, version: version, available: "\(installation.flavor.displayName) build")
        }
        return action
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
            // Unchanged reloads (e.g. after our own writes) don't touch the tables.
            if loaded != addons { addons = loaded }
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
        var rows = addons.compactMap { status -> InstalledRow? in
            guard Self.matches(status, query: query) else { return nil }
            let update: UpdateState? = if case .managed(let addon, _) = status { updateStates[addon.id] } else { nil }
            return InstalledRow(status: status, update: update, flavor: installation.flavor, now: now)
        }
        rows.sort(using: options.sort)
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
}
