import AddonKit
import AppKit
import Observation

enum DetailTab: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case browse = "Browse"
    var id: Self { self }
}

/// A non-blocking message shown at the top of the detail area.
struct Banner: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool = true
}

/// An unmanaged folder offered for adoption.
struct AdoptTarget: Identifiable {
    var folder: String
    var toc: Toc?
    var suggestedRef: AddonRef?
    var id: String { folder }

    init?(_ status: AddonStatus) {
        guard case .unmanaged(let folder, let toc, let suggested) = status else { return nil }
        self.folder = folder
        self.toc = toc
        self.suggestedRef = suggested
    }
}

/// Root model. Owns the manager, the installation list and one `InstallationModel` per installation.
@Observable @MainActor
final class AppModel {
    let manager: any AddonManaging
    /// The concrete manager when running on real data (for detection); nil on mock data.
    let addonManager: AddonManager?
    /// Installing the bundled `addonctl` (first-launch offer and Settings).
    let commandLineTool: CommandLineToolModel

    private(set) var installations: [Installation] = []
    var selectedInstallationID: Installation.ID? {
        didSet {
            selectedAddonID = nil
            selectedBrowseID = nil
            if oldValue != selectedInstallationID { scheduleAutoRefresh() }
        }
    }
    private(set) var isLoadingInstallations = false
    private(set) var isScanning = false
    /// Created lazily from view bodies, so not observed itself; each model is observable.
    @ObservationIgnored private var models: [Installation.ID: InstallationModel] = [:]

    var tab: DetailTab = .installed
    /// Shared by both tabs: filters Installed, queries Browse.
    var searchText = ""
    /// Selection in the Installed tab. Selecting a row opens the inspector.
    var selectedAddonID: AddonStatus.ID? {
        didSet { if selectedAddonID != nil { showInspector = true } }
    }
    /// Selection in the Browse tab.
    var selectedBrowseID: BrowseRow.ID? {
        didSet { if selectedBrowseID != nil { showInspector = true } }
    }
    var showInspector = true
    var banner: Banner?
    /// Unmanaged folder being adopted (drives the Adopt sheet).
    var adoptTarget: AdoptTarget?

    /// The first-launch "Gathering add-on details" sheet.
    var isSeedingPresented = false
    private(set) var seeding: InstallationModel?

    private var didInitialLoad = false
    @ObservationIgnored private var storeWatcher: DirectoryWatcher?
    /// Remembers that the first refresh completed. Nil on sandboxed data, so a temporary data
    /// folder never marks the real app as seeded; there `lastRefresh` alone decides.
    @ObservationIgnored private let seedDefaults: UserDefaults?
    static let didSeedKey = "didSeedAddonDetails"

    /// `offersCommandLineTool`: whether to show the one-time offer to install `addonctl`.
    /// `usesStandardDefaults`: whether first-launch state may be remembered in user defaults.
    init(manager: any AddonManaging, offersCommandLineTool: Bool = false, usesStandardDefaults: Bool = false) {
        self.manager = manager
        self.addonManager = manager as? AddonManager
        self.commandLineTool = CommandLineToolModel(mayOffer: offersCommandLineTool)
        self.seedDefaults = usesStandardDefaults ? .standard : nil
    }

    var selectedInstallation: Installation? {
        installations.first { $0.id == selectedInstallationID }
    }

    /// Model for the selected installation.
    var current: InstallationModel? {
        selectedInstallation.map(model(for:))
    }

    func model(for installation: Installation) -> InstallationModel {
        if let existing = models[installation.id] { return existing }
        let model = InstallationModel(installation: installation, manager: manager) { [weak self] message in
            self?.showError(message)
        }
        model.didReload = { [weak self] in self?.recordStoreFingerprint() }
        models[installation.id] = model
        return model
    }

    /// Total updates across all known installations (menu bar extra).
    var totalUpdateCount: Int {
        models.values.reduce(0) { $0 + $1.updateCount }
    }

    // MARK: Actions

    /// Loads installations and add-ons, then either seeds metadata behind the first-launch
    /// sheet or starts a throttled background refresh. The CLI offer comes after the sheet.
    func initialLoad() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        lastDataVersion = await dataVersion()
        await loadInstallations()
        watchStore()
        scheduleAutoRefresh()
        if let current {
            await current.reload()
            if await needsSeeding(current) {
                seed(current)
                return
            }
            refreshInBackground(current)
        }
        offerCommandLineTool()
    }

    /// No refresh has ever completed: the catalogue, update states and support badges are all empty.
    private func needsSeeding(_ state: InstallationModel) async -> Bool {
        if seedDefaults?.bool(forKey: Self.didSeedKey) == true { return false }
        return await manager.lastRefresh(in: state.installation) == nil
    }

    private func seed(_ state: InstallationModel) {
        seeding = state
        isSeedingPresented = true
        Task {
            await state.startRefresh(force: true).value
            seedDefaults?.set(true, forKey: Self.didSeedKey)
            isSeedingPresented = false
        }
    }

    /// The seeding sheet closed, finished or sent to the background.
    func seedingSheetDidClose() {
        seeding = nil
        offerCommandLineTool()
    }

    private func offerCommandLineTool() {
        Task {
            // Let the window (or the closing sheet) settle before presenting another sheet.
            try? await Task.sleep(for: .seconds(1))
            commandLineTool.offerIfNeeded()
        }
    }

    /// Whether launch, activation and switching installations may start a refresh.
    private var refreshesAutomatically: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.checkForUpdatesOnLaunch) as? Bool ?? true
    }

    /// A non-forced refresh: the core skips it if the last one was recent, so this is cheap to
    /// call on launch, activation and installation switches.
    func refreshInBackground(_ state: InstallationModel? = nil) {
        guard didInitialLoad, !isSeedingPresented, refreshesAutomatically,
              let state = state ?? current else { return }
        state.startRefresh(force: false)
    }

    static let autoRefreshInterval: Duration = .seconds(2 * 60 * 60)
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    /// Refreshes the selected installation every 2 hours while the app runs. One task, restarted
    /// when the selection changes; a tick is skipped if a refresh is already running.
    func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        guard didInitialLoad, let id = selectedInstallationID else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoRefreshInterval)
                guard !Task.isCancelled, let self, let state = self.current, state.installation.id == id else { return }
                if !state.isRefreshing { self.refreshInBackground(state) }
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// Reloads (debounced) whenever the store folder changes, e.g. when `addonctl` installs
    /// or updates something while the app is open (docs/design.md §9.1).
    func watchStore() {
        guard storeWatcher == nil, let directory = addonManager?.store.storeDirectory else { return }
        let watcher = DirectoryWatcher(url: directory) { [weak self] in
            Task { @MainActor in await self?.storeDidChange() }
        }
        watcher.start()
        storeWatcher = watcher
    }

    @ObservationIgnored private var storeFingerprint: Int?

    /// Remembers the store as of the latest reload, so the watcher event caused by the app's
    /// own write (which that reload already reflects) can be ignored.
    private func recordStoreFingerprint() {
        guard let directory = addonManager?.store.storeDirectory else { return }
        storeFingerprint = DirectoryWatcher.fingerprint(of: directory)
    }

    private func storeDidChange() async {
        if let directory = addonManager?.store.storeDirectory,
           DirectoryWatcher.fingerprint(of: directory) == storeFingerprint { return }
        await reload()
    }

    /// Refetches installations and the selected installation's add-ons, so changes made
    /// outside the app (e.g. by `addonctl`) show up. Called when the store folder changes
    /// and when the app becomes active.
    func reload() async {
        guard didInitialLoad else { return }
        await loadInstallations()
        // Drop models for installations that disappeared.
        let ids = Set(installations.map(\.id))
        models = models.filter { ids.contains($0.key) }
        await current?.reload()
    }

    @ObservationIgnored private var lastDataVersion: Int64?

    /// Changes whenever another process (`addonctl`) writes to the metadata database.
    private func dataVersion() async -> Int64? {
        try? await addonManager?.database.dataVersion()
    }

    /// On activation: re-reads metadata only if something else wrote it meanwhile. The app's
    /// own writes reach the models through `MetadataDatabase.changes()`.
    func reloadMetadataIfChanged() async {
        guard didInitialLoad, let version = await dataVersion() else { return }
        let previous = lastDataVersion
        lastDataVersion = version
        guard let previous, previous != version else { return }
        for model in models.values { await model.reloadMetadata() }
    }

    func loadInstallations() async {
        isLoadingInstallations = true
        defer { isLoadingInstallations = false }
        do {
            let loaded = try await manager.installations()
            if loaded != installations { installations = loaded }
            if selectedInstallationID == nil || selectedInstallation == nil {
                selectedInstallationID = installations.first?.id
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Looks for WoW installs again (Spotlight and `/Applications/World of Warcraft`).
    func scanAgain() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            installations = try await manager.detectInstallations()
            if selectedInstallation == nil { selectedInstallationID = installations.first?.id }
            if installations.isEmpty {
                banner = Banner(message: "No World of Warcraft Forever installation found. Use Add Installation… to choose its folder.", isError: false)
            } else {
                await current?.reload()
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Shows a folder picker and registers the chosen folder as an installation.
    func addInstallationWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Installation"
        panel.message = "Choose a World of Warcraft game folder, such as “_classic_beta_”."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/Applications/World of Warcraft", directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addInstallation(at: url) }
    }

    func addInstallation(at url: URL) async {
        do {
            let installation = try await manager.addInstallation(at: url)
            if !installations.contains(where: { $0.id == installation.id }) {
                installations.append(installation)
            }
            selectedInstallationID = installation.id
            let state = model(for: installation)
            await state.reload()
            if !isSeedingPresented, await needsSeeding(state) {
                seed(state)
            } else {
                refreshInBackground(state)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Check for Updates (⌘R): a full refresh, ignoring the core's throttle.
    func checkForUpdates() {
        current?.startRefresh(force: true)
    }

    /// The installation whose refresh is running, for the sidebar's progress bar. Throttled
    /// refreshes that finish at once never report a phase, so they don't flash it.
    var visibleRefresh: (installation: Installation, progress: RefreshProgress)? {
        for installation in installations {
            let state = model(for: installation)
            if let progress = state.refresh.visibleProgress {
                return (installation, progress)
            }
        }
        return nil
    }

    func updateAll() {
        guard let current else { return }
        Task { await current.updateAll() }
    }

    func showError(_ message: String) {
        banner = Banner(message: message)
    }

    /// Jump from a Browse row to the add-on in the Installed tab.
    func reveal(_ ref: AddonRef) {
        tab = .installed
        selectedAddonID = ref.description
        showInspector = true
    }
}
