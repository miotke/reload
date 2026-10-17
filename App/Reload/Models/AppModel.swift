import AddonKit
import AppKit
import Observation

/// A non-blocking message shown at the top of the detail area.
struct Banner: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool = true
}


/// Root model. Owns the manager, the installation list and one `InstallationModel` per installation.
@Observable @MainActor
final class AppModel {
    let manager: any AddonManaging
    /// Installing the bundled `reload` (first-launch offer and Settings).
    let commandLineTool: CommandLineToolModel
    /// Window ▸ Network Activity, following the core from launch.
    let activity = NetworkActivityModel()

    private(set) var installations: [Installation] = []
    var selectedInstallationID: Installation.ID? {
        didSet {
            for model in models.values { model.inspector.clearSelection() }
            if oldValue != selectedInstallationID { scheduleAutoRefresh() }
            if let id = selectedInstallationID { defaults?.set(id, forKey: Self.selectedInstallationKey) }
        }
    }
    private(set) var isLoadingInstallations = false
    private(set) var isScanning = false
    /// Created lazily from view bodies, so not observed itself; each model is observable.
    @ObservationIgnored private var models: [Installation.ID: InstallationModel] = [:]

    /// The sidebar's selection; `ContentView` remembers it per window.
    var section: SidebarItem = .library(.installed) {
        didSet {
            guard section != oldValue else { return }
            // Each section starts unfiltered; `searchAllAddons` carries the text over itself.
            searchText = ""
            // Library sections share one table, so a row selected in one may not be in the next.
            if section.isLibrary, oldValue.isLibrary { current?.inspector.selectedAddonID = nil }
            if section == .library(.installed) { checkInstalledIfStale() }
        }
    }
    /// The toolbar search: filters a library section, queries the catalogue in Browse and categories.
    var searchText = ""
    /// Selecting a row in either table (`InspectorModel`'s selection) opens the inspector.
    var showInspector = true
    var banner: Banner?
    /// Unmanaged folder being adopted (drives the Adopt sheet).
    var adoptTarget: AdoptTarget?
    /// Waiting for the user to confirm an uninstall or a Move to Trash.
    var pendingRemoval: RemovalRequest?

    /// Asks to confirm uninstalling `addon`, naming the add-ons that need it (Settings ▸ General).
    func requestUninstall(_ addon: InstalledAddon) {
        guard let state = current else { return }
        Task {
            let dependents = await state.queue.removalDependents(of: addon.id)
            pendingRemoval = .managed(addon, dependents: dependents)
        }
    }

    /// Runs a confirmed `pendingRemoval` on the current installation.
    func performRemoval(_ request: RemovalRequest) {
        pendingRemoval = nil
        guard let state = current else { return }
        Task {
            switch request {
            case .managed(let addon, _), .forget(let addon): await state.queue.uninstall(addon.id)
            case .unmanaged(let folder): await state.queue.removeUnmanaged(folder.folders, id: request.id)
            }
        }
    }

    /// Waiting for the user to answer "Install BigWigs too?" after an install.
    var pendingDependencies: DependencyPrompt?

    /// Installs the add-ons a confirmed `pendingDependencies` offered.
    func installDependencies(_ prompt: DependencyPrompt) {
        pendingDependencies = nil
        guard let installation = installations.first(where: { $0.id == prompt.installationID }) else { return }
        let queue = model(for: installation).queue
        Task { await queue.installDependencies(prompt.candidates) }
    }

    /// Every add-on source and whether search and Browse use it (Settings ▸ Sources).
    private(set) var sources: [SourceSetting] = []

    /// The sources that are on; Browse re-runs a search when it changes.
    var enabledSources: Set<SourceID> {
        Set(sources.filter(\.isEnabled).map(\.source))
    }

    func loadSources() async {
        let loaded = await manager.sources()
        if loaded != sources { sources = loaded }
    }

    /// Turns a source on or off. Browse's home lists reload through the `.catalogue` change
    /// this reports; a search re-runs because `enabledSources` changed. Turning one on starts
    /// a background refresh, which downloads its listing if it has none, with progress in
    /// the sidebar; search never waits for it.
    func setSource(_ source: SourceID, enabled: Bool) {
        Task {
            do {
                try await manager.setSource(source, enabled: enabled)
            } catch {
                showError("Couldn't change \(source.displayName): \(error.localizedDescription)")
            }
            await loadSources()
            guard enabled, let queue = current?.queue else { return }
            // A refresh already running may be past its catalogue phase; the next one, inside
            // the 2-hour window, only fetches missing listings.
            await queue.startRefresh(force: false).value
            if await !manager.missingListings().isEmpty { queue.startRefresh(force: false) }
        }
    }

    /// The first-launch "Gathering add-on details" sheet.
    var isSeedingPresented = false
    private(set) var seeding: InstallationModel?

    private var didInitialLoad = false
    @ObservationIgnored private var storeWatcher: DirectoryWatcher?
    /// Remembers that the first refresh completed, and the selected installation. Nil on
    /// sandboxed data, so a temporary data folder never marks the real app as seeded or
    /// replaces its remembered installation; there `lastRefresh` alone decides seeding.
    @ObservationIgnored private let defaults: UserDefaults?
    static let didSeedKey = "didSeedAddonDetails"
    static let selectedInstallationKey = "selectedInstallation"

    /// `offersCommandLineTool`: whether to show the one-time offer to install `reload`.
    /// `usesStandardDefaults`: whether first-launch state may be remembered in user defaults.
    init(manager: any AddonManaging, offersCommandLineTool: Bool = false, usesStandardDefaults: Bool = false) {
        self.manager = manager
        self.commandLineTool = CommandLineToolModel(mayOffer: offersCommandLineTool)
        self.defaults = usesStandardDefaults ? .standard : nil
    }

    /// False on sandboxed data, where first-launch steps aren't remembered, so there's nothing to reset.
    var remembersFirstLaunchSteps: Bool { defaults != nil }

    /// Shows the seeding sheet and the `reload` offer again on the next launch.
    func resetFirstLaunchSteps() {
        if let defaults { FirstLaunchSteps.reset(in: defaults) }
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
        model.installed.didReload = { [weak self] in self?.recordStoreFingerprint() }
        model.inspector.didSelect = { [weak self] in self?.showInspector = true }
        model.queue.didFindMissingDependencies = { [weak self] prompt in self?.pendingDependencies = prompt }
        models[installation.id] = model
        return model
    }

    /// The sidebar's categories: the core's Browse content once loaded, its static list before.
    var categories: [SearchCategory] {
        if let loaded = current?.browse.content?.categories, !loaded.isEmpty { return loaded }
        return SearchAliases.categories
    }

    /// Total updates across all known installations (menu bar extra).
    var totalUpdateCount: Int {
        models.values.reduce(0) { $0 + $1.installed.updateCount }
    }

    // MARK: Actions

    /// Loads installations and add-ons, then either seeds metadata behind the first-launch
    /// sheet or starts a throttled background refresh. The CLI offer comes after the sheet.
    func initialLoad() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        activity.start(manager)
        lastDataVersion = await dataVersion()
        await loadSources()
        await loadInstallations()
        watchStore()
        scheduleAutoRefresh()
        if let current {
            await current.installed.reload()
            if await needsSeeding(current) {
                seed(current)
                return
            }
            refreshInBackground(current)
        }
        offerCommandLineTool()
    }

    /// No refresh has ever completed (the catalogue, update states and support badges are all
    /// empty), or Settings reset the first-launch steps.
    private func needsSeeding(_ state: InstallationModel) async -> Bool {
        let didSeed = defaults?.object(forKey: Self.didSeedKey) as? Bool
        // The stored flag decides alone, so the refresh date is only read when there's none.
        let hasRefreshed = didSeed == nil ? await manager.lastRefresh(in: state.installation) != nil : true
        return FirstLaunchSteps.needsSeeding(didSeed: didSeed, hasRefreshed: hasRefreshed)
    }

    private func seed(_ state: InstallationModel) {
        seeding = state
        isSeedingPresented = true
        Task {
            await state.queue.startRefresh(force: true).value
            defaults?.set(true, forKey: Self.didSeedKey)
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
        state.queue.startRefresh(force: false)
    }

    /// Opening Installed rechecks the add-ons whose answers are stale, under the same
    /// conditions as the background refresh (docs/features/refresh.md#opening-installed).
    func checkInstalledIfStale() {
        guard didInitialLoad, !isSeedingPresented, refreshesAutomatically, let current else { return }
        current.queue.checkInstalledIfStale()
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
                if !state.queue.isRefreshing { self.refreshInBackground(state) }
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// Reloads (debounced) whenever the store folder changes, e.g. when `reload` installs
    /// or updates something while the app is open (docs/app/live-data.md).
    func watchStore() {
        guard storeWatcher == nil else { return }
        let watcher = DirectoryWatcher(url: manager.storeDirectory) { [weak self] in
            Task { @MainActor in await self?.storeDidChange() }
        }
        watcher.start()
        storeWatcher = watcher
    }

    @ObservationIgnored private var storeFingerprint: Int?

    /// Remembers the store as of the latest reload, so the watcher event caused by the app's
    /// own write (which that reload already reflects) can be ignored.
    private func recordStoreFingerprint() {
        storeFingerprint = DirectoryWatcher.fingerprint(of: manager.storeDirectory)
    }

    private func storeDidChange() async {
        if DirectoryWatcher.fingerprint(of: manager.storeDirectory) == storeFingerprint { return }
        await reload()
    }

    /// Refetches installations and the selected installation's add-ons, so changes made
    /// outside the app (e.g. by `reload`) show up. Called when the store folder changes
    /// and when the app becomes active.
    func reload() async {
        guard didInitialLoad else { return }
        await loadInstallations()
        // Drop models for installations that disappeared.
        let ids = Set(installations.map(\.id))
        models = models.filter { ids.contains($0.key) }
        await current?.installed.reload()
    }

    @ObservationIgnored private var lastDataVersion: Int64?

    /// Changes whenever another process (`reload`) writes to the metadata database.
    private func dataVersion() async -> Int64? {
        await manager.metadataVersion()
    }

    /// On activation: re-reads metadata only if something else wrote it meanwhile. The app's
    /// own writes reach the models through `metadataChanges()`.
    func reloadMetadataIfChanged() async {
        guard didInitialLoad, let version = await dataVersion() else { return }
        let previous = lastDataVersion
        lastDataVersion = version
        guard let previous, previous != version else { return }
        // `reload sources` may have changed them.
        await loadSources()
        for model in models.values { await model.browse.reloadMetadata() }
    }

    func loadInstallations() async {
        isLoadingInstallations = true
        defer { isLoadingInstallations = false }
        do {
            let loaded = try await manager.installations()
            if loaded != installations { installations = loaded }
            if selectedInstallationID == nil || selectedInstallation == nil {
                let remembered = defaults?.string(forKey: Self.selectedInstallationKey)
                selectedInstallationID = (installations.first { $0.id == remembered } ?? installations.first)?.id
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
                await current?.installed.reload()
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
            await state.installed.reload()
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
        current?.queue.startRefresh(force: true)
    }

    /// The installation whose refresh is running, for the sidebar's progress bar. Throttled
    /// refreshes that finish at once never report a phase, so they don't flash it.
    var visibleRefresh: (installation: Installation, progress: RefreshProgress)? {
        for installation in installations {
            let state = model(for: installation)
            if let progress = state.queue.refresh.visibleProgress {
                return (installation, progress)
            }
        }
        return nil
    }

    func updateAll() {
        guard let current else { return }
        Task { await current.queue.updateAll() }
    }

    func showError(_ message: String) {
        banner = Banner(message: message)
    }

    /// Browse, searching for `text`: the inspector's Search for a required add-on. The add-on
    /// that asked mustn't stay in the inspector as if it were the answer, so the selection is
    /// cleared now and becomes the first result, or stays empty, when the search finishes.
    func searchBrowse(for text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        current?.inspector.selectedBrowseID = nil
        current?.browse.revealQuery = query
        section = .browse
        searchText = query
    }

    /// "Search all add-ons" (or Return) in a library section: the same text, in Browse.
    func searchAllAddons() {
        let text = searchText
        section = .browse
        searchText = text
    }

    /// Jump from a Browse row to the add-on in Installed.
    func reveal(_ ref: AddonRef) {
        section = .library(.installed)
        current?.inspector.selectedAddonID = ref.description
        showInspector = true
    }
}
