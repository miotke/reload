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
    private(set) var isCheckingForUpdates = false
    private(set) var isUpdatingAll = false
    /// Keyed by `AddonStatus.id` / `AddonRef.description`.
    private(set) var activity: [String: RowActivity] = [:]
    var rowErrors: [String: String] = [:]

    // Browse tab
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false
    /// Popular / recently updated / categories for an empty query; nil until loaded.
    private(set) var browse: BrowseContent?
    /// Results that need `force` to overwrite an unmanaged folder.
    private(set) var needsOverwrite: Set<AddonRef> = []

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

    func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            updateStates = try await manager.checkForUpdates(in: installation)
            lastChecked = .now
            for (ref, state) in updateStates {
                if case .failed(let message) = state { rowErrors[ref.description] = message }
                else { rowErrors[ref.description] = nil }
            }
        } catch {
            reportError(error.localizedDescription)
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
            if let states = try? await self.manager.checkForUpdates(in: self.installation) {
                self.updateStates = states
            }
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
        defer { if !Task.isCancelled { isSearching = false } }
        for await results in manager.search(query, in: installation) {
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }

    func clearSearch() {
        searchResults = []
        isSearching = false
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
}
