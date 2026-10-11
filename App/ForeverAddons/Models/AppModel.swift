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

    private(set) var installations: [Installation] = []
    var selectedInstallationID: Installation.ID? {
        didSet { selectedAddonID = nil }
    }
    private(set) var isLoadingInstallations = false
    private(set) var isScanning = false
    /// Created lazily from view bodies, so not observed itself; each model is observable.
    @ObservationIgnored private var models: [Installation.ID: InstallationModel] = [:]

    var tab: DetailTab = .installed
    /// Shared by both tabs: filters Installed, queries Browse.
    var searchText = ""
    var selectedAddonID: AddonStatus.ID?
    var showInspector = true
    var banner: Banner?
    /// Unmanaged folder being adopted (drives the Adopt sheet).
    var adoptTarget: AdoptTarget?

    private var didInitialLoad = false
    @ObservationIgnored private var storeWatcher: DirectoryWatcher?

    init(manager: any AddonManaging) {
        self.manager = manager
        self.addonManager = manager as? AddonManager
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
        models[installation.id] = model
        return model
    }

    /// Total updates across all known installations (menu bar extra).
    var totalUpdateCount: Int {
        models.values.reduce(0) { $0 + $1.updateCount }
    }

    // MARK: Actions

    func initialLoad(checkForUpdates: Bool) async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        await loadInstallations()
        watchStore()
        guard let current else { return }
        await current.reload()
        if checkForUpdates { await current.checkForUpdates() }
    }

    /// Reloads (debounced) whenever the store folder changes, e.g. when `addonctl` installs
    /// or updates something while the app is open (DESIGN.md §9.1).
    func watchStore() {
        guard storeWatcher == nil, let directory = addonManager?.store.storeDirectory else { return }
        let watcher = DirectoryWatcher(url: directory) { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
        watcher.start()
        storeWatcher = watcher
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

    func loadInstallations() async {
        isLoadingInstallations = true
        defer { isLoadingInstallations = false }
        do {
            installations = try await manager.installations()
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
            if let addonManager {
                installations = try await addonManager.detectInstallations()
            } else {
                installations = try await manager.installations()
            }
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
            await model(for: installation).reload()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func checkForUpdates() {
        guard let current else { return }
        Task { await current.checkForUpdates() }
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
