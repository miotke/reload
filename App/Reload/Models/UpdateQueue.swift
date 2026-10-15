import AddonKit
import Foundation
import Observation

/// Checks, installs, updates and the other per-row operations of one installation, with the
/// progress and errors each row shows (`row(_:)`). Every action reports failures on the
/// affected row and never throws to the UI.
@Observable @MainActor
final class UpdateQueue {
    let installation: Installation
    private let manager: any AddonManaging
    private let installed: InstalledModel
    /// An install finished; Browse marks the result installed without waiting for a reload.
    @ObservationIgnored var didInstall: (@MainActor (InstalledAddon) -> Void)?
    /// A refresh that did work finished; Browse re-reads rows that newly qualify for its lists.
    @ObservationIgnored var didFinishRefresh: (@MainActor () async -> Void)?
    /// An install left required add-ons missing and the policy is to ask; the window asks.
    @ObservationIgnored var didFindMissingDependencies: (@MainActor (DependencyPrompt) -> Void)?
    /// Settings ▸ General, read when needed; tests replace them.
    @ObservationIgnored var dependencyPolicy: @MainActor () -> DependencyPolicy = { DependencyPolicy.stored() }
    @ObservationIgnored var warnsBeforeRemovingDependencies: @MainActor () -> Bool = { RemovalWarning.isOn() }
    @ObservationIgnored var defaultChannel: @MainActor () -> Channel = {
        UserDefaults.standard.string(forKey: SettingsKey.defaultChannel).flatMap(Channel.init(rawValue:)) ?? .stable
    }

    @ObservationIgnored private var rowStates: [String: RowState] = [:]
    let refresh = RefreshStatus()
    private(set) var isRefreshing = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// When the last refresh finished, for "Last fetched" and the Installed subtitle.
    private(set) var lastChecked: Date?
    private(set) var isUpdatingAll = false

    init(installation: Installation, manager: any AddonManaging, installed: InstalledModel) {
        self.installation = installation
        self.manager = manager
        self.installed = installed
    }

    /// The state object for a row, created on first use. Keyed by `AddonStatus.id` / `AddonRef.description`.
    func row(_ id: String) -> RowState {
        if let existing = rowStates[id] { return existing }
        let state = RowState()
        rowStates[id] = state
        return state
    }

    // MARK: Check

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
        // Badges change live through Browse's metadata observation; the reload at the end
        // picks up rows that newly qualify for Popular or Recently Updated.
        for await progress in manager.refresh(in: installation, force: force) {
            refresh.progress = progress
            guard progress.phase == .finished else {
                didWork = true
                continue
            }
            if let updates = progress.updates { apply(updates) }
            lastChecked = await manager.lastRefresh(in: installation) ?? .now
        }
        if didWork { await didFinishRefresh?() }
    }

    /// Reads when the last refresh finished, for "Last fetched" before this session refreshes.
    func loadLastRefresh() async {
        guard lastChecked == nil else { return }
        lastChecked = await manager.lastRefresh(in: installation)
    }

    /// Also used by tests to set update states without a refresh.
    func apply(_ updates: [AddonRef: UpdateState]) {
        installed.setUpdateStates(updates)
        for (ref, state) in updates {
            let error: String? = if case .failed(let message) = state { message } else { nil }
            if row(ref.description).error != error { row(ref.description).error = error }
        }
    }

    // MARK: Update

    func updateAll() async {
        await update(installed.refsWithUpdates)
    }

    /// Installs the releases the last check found (`.available`), without resolving them
    /// again, and drives per-row progress. Refs without one are ignored. A failed row keeps
    /// its error; the rest continue.
    func update(_ refs: [AddonRef]) async {
        let releases = refs.compactMap(installed.availableRelease(for:))
        guard !releases.isEmpty else { return }
        let refs = releases.map(\.ref)
        isUpdatingAll = true
        defer { isUpdatingAll = false }
        for ref in refs { row(ref.description).error = nil }
        for await event in manager.update(releases: releases, in: installation) { apply(event) }
        // Clear any rows the stream never finished (e.g. cancelled).
        for ref in refs where row(ref.description).activity != nil { row(ref.description).activity = nil }
        await installed.reload()
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
            installed.batchingRows {
                installed.setUpdateState(.upToDate, for: addon.id)
                installed.replace(addon)
            }
        case .skipped(let ref, _):
            row(ref.description).activity = nil
        case .failed(let ref, let message):
            row(ref.description).activity = nil
            row(ref.description).error = message
        }
    }

    // MARK: Install and manage

    /// Installs `ref`, showing download progress on its row, then the installing phase. With
    /// `allowFamilyFallback`, the Retail build of an add-on with no Forever build.
    func install(_ ref: AddonRef, channel: Channel, force: Bool = false, allowFamilyFallback: Bool = false) async {
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
            result = .success(try await manager.install(
                ref, into: installation, channel: channel, force: force, allowFamilyFallback: allowFamilyFallback
            ) { fraction in
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
            didInstall?(addon)
            await installed.reload()
            await followUpDependencies(of: addon)
        case .failure(let error):
            if case .unmanagedFolderExists = error as? AddonError { row.needsOverwrite = true }
            row.error = error.localizedDescription
        }
    }

    // MARK: Required add-ons

    /// After an install: asks the core what `addon` still needs, then installs the suggested
    /// add-ons, asks about them, or leaves the Installed warning, as Settings says.
    func followUpDependencies(of addon: InstalledAddon) async {
        let missing = await manager.missingDependencies(of: addon.id, in: installation)
        switch DependencyFollowUp(addonName: addon.name, missing: missing, policy: dependencyPolicy(), installationID: installation.id) {
        case .nothing: break
        case .ask(let prompt): didFindMissingDependencies?(prompt)
        case .install(let candidates): await installDependencies(candidates)
        }
    }

    /// Installs each candidate in turn through `install`, so each shows progress and errors
    /// on its own row and gets its own follow-up. Skips ones already installed or installing.
    func installDependencies(_ candidates: [DependencyCandidate]) async {
        for candidate in candidates {
            guard installed.addon(for: candidate.ref) == nil, row(candidate.ref.description).activity == nil else { continue }
            await install(candidate.ref, channel: defaultChannel())
        }
    }

    /// Managed add-ons that stop loading without `ref`, for the uninstall confirmation; none
    /// when Settings doesn't warn.
    func removalDependents(of ref: AddonRef) async -> [InstalledAddon] {
        guard warnsBeforeRemovingDependencies() else { return [] }
        return await manager.dependents(of: ref, in: installation)
    }

    func uninstall(_ ref: AddonRef) async {
        await perform(ref.description, label: "Uninstalling…") {
            try await self.manager.uninstall(ref, from: self.installation)
            self.installed.setUpdateState(nil, for: ref)
        }
    }

    func rollback(_ ref: AddonRef) async {
        await perform(ref.description, label: "Rolling back…") {
            try await self.manager.rollback(ref, in: self.installation)
            // Rollback pins the add-on, so there's nothing to check.
            self.installed.setUpdateState(.pinned, for: ref)
        }
    }

    func setPinned(_ pinned: Bool, for ref: AddonRef) async {
        await perform(ref.description, label: nil) {
            try await self.manager.setPinned(pinned, for: ref, in: self.installation)
            if pinned {
                self.installed.setUpdateState(.pinned, for: ref)
            } else if self.installed.updateStates[ref] == .pinned {
                self.installed.setUpdateState(nil, for: ref)
            }
        }
    }

    func setChannel(_ channel: Channel, for ref: AddonRef) async {
        await perform(ref.description, label: nil) {
            try await self.manager.setChannel(channel, for: ref, in: self.installation)
            self.installed.setUpdateState(nil, for: ref)
        }
    }

    // MARK: Unmanaged folders

    /// Returns true on success so the sheet can dismiss. With `release` (from a preview) it's
    /// installed as is; otherwise `ref` is resolved first.
    func adopt(folder: String, as ref: AddonRef, release: ResolvedRelease? = nil) async -> Bool {
        var adopted: InstalledAddon?
        await perform(AddonStatus.unmanagedID(folder), label: "Adopting…") {
            if let release, release.ref == ref {
                adopted = try await self.manager.adopt(release, in: self.installation)
            } else {
                adopted = try await self.manager.adopt(folder: folder, as: ref, in: self.installation)
            }
        }
        // Not awaited, so the sheet closes first; the window asks once it has.
        if let adopted { Task { await followUpDependencies(of: adopted) } }
        return adopted != nil
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
        if !Task.isCancelled { await installed.reload() }
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
        await installed.reload()
    }
}
