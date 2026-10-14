import Foundation

/// Resolving, installing, adopting and removing add-ons (docs/features/installing.md).
extension AddonManager {
    /// Stable channel: tries the quota-free route first (latest tag + release.json), and
    /// uses the API only when that can't decide.
    public func resolve(_ ref: AddonRef, for installation: Installation, channel: Channel) async throws -> ResolvedRelease {
        try await resolve(ref, flavor: installation.flavor, channel: channel)
    }

    /// Like `resolve(_:for:channel:)`. With `allowFamilyFallback`, an add-on with no build for
    /// the installation's flavor resolves to its `fallbackFlavor` build (the Retail build on
    /// Forever), marked in `flavorBuild`. Without it, or with no fallback build either, that's
    /// `noCompatibleRelease` for the installation's flavor (docs/features/release-selection.md#retail-build-on-forever).
    public func resolve(_ ref: AddonRef, for installation: Installation, channel: Channel, allowFamilyFallback: Bool) async throws -> ResolvedRelease {
        let own = installation.flavor
        do {
            return try await resolve(ref, flavor: own, channel: channel)
        } catch AddonError.noCompatibleRelease {
            guard allowFamilyFallback, let fallback = own.fallbackFlavor,
                  var release = try? await resolve(ref, flavor: fallback, channel: channel) else {
                throw AddonError.noCompatibleRelease(ref, own)
            }
            release.flavorBuild = fallback
            release.reasoning.insert("no \(own.rawValue) build; the \(fallback.displayName) build was asked for (allowFamilyFallback)", at: 0)
            return release
        }
    }

    /// Stable channel: tries the quota-free route first (latest tag + release.json), and
    /// uses the API only when that can't decide.
    func resolve(_ ref: AddonRef, flavor: Flavor, channel: Channel) async throws -> ResolvedRelease {
        // Hosts have no prereleases: both channels get the latest file.
        guard ref.source == .github else { return try await resolveHosted(ref, flavor: flavor, policy: .forceRevalidate) }
        if channel == .stable, let release = await github.latest.quotaFreeResolve(ref, flavor: flavor, policy: .forceRevalidate) {
            return release
        }
        return try await resolve(ref, flavor: flavor, channel: channel, etag: nil).release
    }

    /// `release` is nil only when `etag` was given and nothing changed.
    private func resolve(
        _ ref: AddonRef, flavor: Flavor, channel: Channel, etag: String?
    ) async throws -> (release: ResolvedRelease, etag: String?) {
        guard ref.source == .github else { throw AddonError.invalidReference(ref.description) }
        switch try await github.source.resolve(ref, flavor: flavor, channel: channel, etag: etag) {
        case .release(let release, let etag):
            return (release, etag)
        case .notModified:
            // Only possible with a caller ETag; ask again without one for the full release.
            return try await resolve(ref, flavor: flavor, channel: channel, etag: nil)
        }
    }

    @discardableResult
    public func install(
        _ ref: AddonRef, into installation: Installation, channel: Channel, force: Bool, allowFamilyFallback: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledAddon {
        let release = try await resolve(ref, for: installation, channel: channel, allowFamilyFallback: allowFamilyFallback)
        return try await install(release, into: installation, channel: channel, force: force, pin: nil, progress: progress)
    }

    /// Downloads and installs `release`, recording it in the store under the store lock. The
    /// flavors its TOCs ship are recorded for repos whose release.json didn't say (decision 0019).
    @discardableResult
    func install(
        _ release: ResolvedRelease, into installation: Installation, channel: Channel?, force: Bool,
        pin: Bool?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledAddon {
        let archive = try await downloader.download(release, progress: progress)
        let installer = self.installer
        // Extraction is the slow part; it runs before the lock the CLI and app wait on, and
        // off this actor. Only the ownership check, the swap and the store write are locked.
        let (prepared, shipped) = try await Self.prepare(installer, archive: archive, into: installation)
        await database.setReleaseFolders(prepared.folders, tag: release.version, for: release.ref.key, at: now())
        if !shipped.isEmpty {
            await supportCache.setAvailableFlavors(shipped, tag: release.version, source: .inspection, for: release.ref)
        }
        do {
            return try await store.withLock { store in
                let current = try store.addons(in: installation)
                let previous = current.first { $0.id == release.ref }
                var addon = try installer.commit(prepared, release: release, current: current, force: force)
                if let channel { addon.channel = channel }
                if let pin { addon.pinned = pin }
                addon.changelog = release.changelog
                addon.installedFlavorBuild = release.flavorBuild
                addon.etag = nil
                if let previous, previous.releaseID != release.releaseID {
                    addon.previousRelease = previous.snapshot
                } else {
                    addon.previousRelease = previous?.previousRelease
                }
                try store.upsert(addon, in: installation)
                return addon
            }
        } catch {
            // `commit` cleans up after itself; this covers failures before it ran.
            prepared.discard()
            throw error
        }
    }

    /// Extracts to staging and reads the flavors the extracted TOCs ship.
    @concurrent
    private static func prepare(
        _ installer: Installer, archive: URL, into installation: Installation
    ) async throws -> (Installer.PreparedInstall, Set<Flavor>) {
        let prepared = try installer.prepare(archive: archive, into: installation)
        let folders = prepared.folders.map { prepared.extracted.appending(path: $0, directoryHint: .isDirectory) }
        return (prepared, ZipInspector.availableFlavors(addonFolders: folders))
    }

    public func adopt(folder: String, as ref: AddonRef, in installation: Installation) async throws -> InstalledAddon {
        let release = try await resolve(ref, for: installation, channel: .stable)
        return try await adopt(release, in: installation)
    }

    // MARK: - Adoption (docs/features/installing.md#adopting-unmanaged-folders)

    /// Installs a release `adoptionPreview` resolved, over whatever unmanaged folders it ships.
    public func adopt(_ release: ResolvedRelease, in installation: Installation) async throws -> InstalledAddon {
        try await install(release, into: installation, channel: .stable, force: true, pin: nil, progress: { _ in })
    }

    /// Repositories `folder` probably comes from, best first, with reasons: TOC GitHub links,
    /// then CurseForge, Wago and WoWInterface IDs and names matched against the local
    /// catalogue (decision 0018). No network.
    public func adoptionCandidates(folder: String, in installation: Installation) async -> [AdoptionCandidate] {
        let unmanaged = UnmanagedFolder(reading: folder, in: installation.addonsDirectory, flavor: installation.flavor)
        return await catalogue.adoptionIndex().candidates(folder: folder, hints: unmanaged.hints)
    }

    /// Resolves `ref`'s stable release for the installation's flavor (quota-free when it has
    /// a release.json), downloads its zip to the cache the install reuses, and says which
    /// folders adopting it would replace. `folders` are the unmanaged folders being adopted;
    /// those the zip doesn't ship come back in `notCovered`.
    /// - Throws: `AddonError.noCompatibleRelease` when no release has a build for the flavor.
    public func adoptionPreview(for ref: AddonRef, folders: [String], in installation: Installation) async throws -> AdoptionPreview {
        let release = try await resolve(ref, for: installation, channel: .stable)
        let archive = try await downloader.download(release, progress: { _ in })
        let shipped = try await Self.topLevelFolders(archive)
        await database.setReleaseFolders(shipped, tag: release.version, for: ref.key, at: now())

        let managed = try await store.addons(in: installation)
        var replaces: [String] = [], adds: [String] = [], conflicts: [String: AddonRef] = [:]
        for folder in shipped {
            if let owner = managed.first(where: { $0.id != ref && $0.folders.contains { Installer.same($0, folder) } }) {
                conflicts[folder] = owner.id
            } else if Installer.exists(installation.addonsDirectory.appending(path: folder, directoryHint: .isDirectory))
                        && !managed.contains(where: { $0.id == ref && $0.folders.contains { Installer.same($0, folder) } }) {
                replaces.append(folder)
            } else {
                adds.append(folder)
            }
        }
        let notCovered = folders.filter { folder in !shipped.contains { Installer.same($0, folder) } }
        return AdoptionPreview(release: release, folders: shipped, replaces: replaces, adds: adds, conflicts: conflicts, notCovered: notCovered)
    }

    @concurrent
    private static func topLevelFolders(_ archive: URL) async throws -> [String] {
        try ZipExtractor.topLevelFolders(in: archive)
    }

    /// Moves unmanaged `folders` to the Trash with the installer's trash handler. Every folder
    /// is checked before any moves: `Blizzard_*`, folders a managed add-on owns, names that
    /// aren't a single folder in `AddOns/`, and folders that don't exist are refused with
    /// `AddonError.cannotRemove`. Returns the folders removed, as named on disk.
    @discardableResult
    public func removeUnmanaged(folders: [String], from installation: Installation) async throws -> [String] {
        let installer = self.installer
        return try await store.withLock { store in
            try installer.removeUnmanaged(folders, from: installation, managed: store.addons(in: installation))
        }
    }

    public func uninstall(_ ref: AddonRef, from installation: Installation) async throws {
        let installer = self.installer
        try await store.withLock { store in
            guard let addon = try store.addons(in: installation).first(where: { $0.id == ref }) else {
                throw AddonError.notInstalled(ref)
            }
            try installer.uninstall(addon, from: installation)
            try store.remove(ref: ref, in: installation)
        }
    }
}
