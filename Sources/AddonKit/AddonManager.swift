import Foundation

/// The real `AddonManaging` implementation, shared by the app and `addonctl` (docs/design.md §6.10).
public actor AddonManager: AddonManaging {
    public nonisolated let directories: AppDirectories
    public nonisolated let store: InstallStore

    let http: any HTTPClient
    let locator: InstallationLocator
    let installer: Installer
    let downloader: Downloader
    let keychain: KeychainStore
    let environment: [String: String]
    let catalogue: CatalogueSource
    let supportCache: SupportCache
    /// Used only for `parse`, which never touches the network or the token.
    let parser: GitHubSource

    private var github: GitHubSource
    private var searchCoordinator: SearchCoordinator
    /// Automatic detection runs at most once per process; later scans are explicit.
    private var didAutoDetect = false

    /// Add-ons checked or updated at once.
    static let maxConcurrentOperations = 4

    public init(
        directories: AppDirectories = .standard(),
        http: any HTTPClient = URLSessionHTTPClient(),
        downloadTransport: any DownloadTransport = URLSessionDownloadTransport(),
        locator: InstallationLocator = InstallationLocator(),
        installer: Installer = Installer(),
        keychain: KeychainStore = KeychainStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.directories = directories
        self.http = http
        self.locator = locator
        self.installer = installer
        self.keychain = keychain
        self.environment = environment
        self.store = InstallStore(directories: directories)
        self.downloader = Downloader(cachesDirectory: directories.caches, transport: downloadTransport)
        self.catalogue = CatalogueSource(http: http, cacheDirectory: directories.caches)
        self.supportCache = SupportCache(directory: directories.caches)
        self.parser = GitHubSource(http: http)

        let token = Self.token(environment: environment, keychain: keychain)
        let github = GitHubSource(http: http, token: token, cacheDirectory: directories.caches)
        self.github = github
        self.searchCoordinator = SearchCoordinator(
            catalogue: catalogue,
            github: GitHubSearchProvider(http: http, token: token),
            support: github,
            supportCache: supportCache
        )
    }

    /// `ADDONS_GITHUB_TOKEN`, then `GITHUB_TOKEN`, then the Keychain (docs/design.md §9.1).
    static func token(environment: [String: String], keychain: KeychainStore) -> String? {
        for key in ["ADDONS_GITHUB_TOKEN", "GITHUB_TOKEN"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return keychain.get()
    }

    public func tokenDidChange() async {
        let token = Self.token(environment: environment, keychain: keychain)
        github = GitHubSource(http: http, token: token, cacheDirectory: directories.caches)
        searchCoordinator = SearchCoordinator(
            catalogue: catalogue,
            github: GitHubSearchProvider(http: http, token: token),
            support: github,
            supportCache: supportCache
        )
    }

    /// Remaining GitHub API calls and when the limit resets, as last reported by GitHub.
    public func rateLimit() async -> (remaining: Int?, resetAt: Date?) {
        await github.rateLimit()
    }

    // MARK: - Installations

    /// Stored installations. The first call in a process runs detection if nothing is stored yet.
    public func installations() async throws -> [Installation] {
        let stored = try await store.installations()
        guard stored.isEmpty, !didAutoDetect else { return stored }
        didAutoDetect = true
        return try await detectInstallations()
    }

    /// Scans for WoW installs and stores any that aren't known yet. Returns all stored installations.
    @discardableResult
    public func detectInstallations() async throws -> [Installation] {
        let known = Set(try await store.installations().map(\.id))
        for installation in await locator.locate() where !known.contains(installation.id) {
            try await store.save(installation)
        }
        return try await store.installations()
    }

    public func addInstallation(at url: URL) async throws -> Installation {
        let installation = try locator.installation(at: url)
        try await store.save(installation)
        return installation
    }

    public func removeInstallation(_ installation: Installation) async throws {
        try await store.remove(installationID: installation.id)
    }

    // MARK: - Add-ons

    public func addons(in installation: Installation) async throws -> [AddonStatus] {
        try await store.reconcile(installation)
    }

    /// Managed add-ons only, straight from the store.
    public func installedAddons(in installation: Installation) async throws -> [InstalledAddon] {
        try await store.addons(in: installation)
    }

    /// Turns user input into refs: an `owner/repo` or URL, an installed add-on's name or
    /// folder, or an exact catalogue name. More than one result means the input is ambiguous.
    public func lookup(_ input: String, in installation: Installation) async throws -> [AddonRef] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = parser.parse(text) { return [ref] }

        let installed = try await store.addons(in: installation)
        let installedMatches = installed.filter { addon in
            addon.name.caseInsensitiveCompare(text) == .orderedSame
                || addon.id.identifier.split(separator: "/").last.map { $0.caseInsensitiveCompare(text) == .orderedSame } == true
                || addon.folders.contains { $0.caseInsensitiveCompare(text) == .orderedSame }
        }
        if !installedMatches.isEmpty { return installedMatches.map(\.id) }

        let entries = try await catalogue.entries()
        let exact = entries.filter { entry in
            entry.name.caseInsensitiveCompare(text) == .orderedSame
                || entry.fullName.split(separator: "/").last.map { $0.caseInsensitiveCompare(text) == .orderedSame } == true
        }
        return exact.map(\.ref)
    }

    // MARK: - Search

    public nonisolated func search(_ query: SearchQuery, in installation: Installation) -> AsyncStream<[SearchResult]> {
        AsyncStream { continuation in
            let task = Task {
                let installed = (try? await self.addons(in: installation)) ?? []
                let coordinator = await self.searchCoordinator
                for await results in coordinator.search(query, installed: installed) {
                    continuation.yield(results)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func browse(in installation: Installation) async -> BrowseContent {
        let browse = await searchCoordinator.browse(flavor: installation.flavor)
        let installed = Dictionary(
            ((try? await store.addons(in: installation)) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let markInstalled = { (results: [SearchResult]) in
            results.map { result in
                var result = result
                result.installed = installed[result.id]
                result.origin.formUnion(result.installed == nil ? [] : [.installed])
                return result
            }
        }
        return BrowseContent(popular: markInstalled(browse.popular), recent: markInstalled(browse.recent), categories: browse.categories)
    }

    // MARK: - Resolve & install

    public func resolve(_ ref: AddonRef, for installation: Installation, channel: Channel) async throws -> ResolvedRelease {
        try await resolve(ref, for: installation, channel: channel, etag: nil).release
    }

    /// `release` is nil only when `etag` was given and nothing changed.
    private func resolve(
        _ ref: AddonRef, for installation: Installation, channel: Channel, etag: String?
    ) async throws -> (release: ResolvedRelease, etag: String?) {
        guard ref.source == .github else { throw AddonError.invalidReference(ref.description) }
        switch try await github.resolve(ref, flavor: installation.flavor, channel: channel, etag: etag) {
        case .release(let release, let etag):
            return (release, etag)
        case .notModified:
            // Only possible with a caller ETag; ask again without one for the full release.
            return try await resolve(ref, for: installation, channel: channel, etag: nil)
        }
    }

    @discardableResult
    public func install(
        _ ref: AddonRef, into installation: Installation, channel: Channel, force: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledAddon {
        let release = try await resolve(ref, for: installation, channel: channel)
        return try await install(release, into: installation, channel: channel, force: force, pin: nil, progress: progress)
    }

    /// Downloads and installs `release`, recording it in the store under the store lock.
    @discardableResult
    func install(
        _ release: ResolvedRelease, into installation: Installation, channel: Channel?, force: Bool,
        pin: Bool?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledAddon {
        let archive = try await downloader.download(release, progress: progress)
        let installer = self.installer
        return try await store.withLock { store in
            let current = try store.addons(in: installation)
            let previous = current.first { $0.id == release.ref }
            var addon = try installer.install(archive: archive, into: installation, release: release, current: current, force: force)
            if let channel { addon.channel = channel }
            if let pin { addon.pinned = pin }
            addon.changelog = release.changelog
            addon.etag = nil
            if let previous, previous.releaseID != release.releaseID {
                addon.previousRelease = previous.snapshot
            } else {
                addon.previousRelease = previous?.previousRelease
            }
            try store.upsert(addon, in: installation)
            return addon
        }
    }

    public func adopt(folder: String, as ref: AddonRef, in installation: Installation) async throws -> InstalledAddon {
        let release = try await resolve(ref, for: installation, channel: .stable)
        return try await install(release, into: installation, channel: .stable, force: true, pin: nil, progress: { _ in })
    }

    // MARK: - Updates

    public func checkForUpdates(in installation: Installation) async throws -> [AddonRef: UpdateState] {
        let addons = try await store.addons(in: installation)
        var states: [AddonRef: UpdateState] = [:]

        try await withThrowingTaskGroup(of: (AddonRef, UpdateState, String?).self) { group in
            var pending = addons[...]
            func addNext() {
                guard let addon = pending.popFirst() else { return }
                group.addTask {
                    let (state, etag) = await self.updateState(of: addon, in: installation)
                    return (addon.id, state, etag)
                }
            }
            for _ in 0..<Self.maxConcurrentOperations { addNext() }
            while let (ref, state, etag) = try await group.next() {
                states[ref] = state
                if case .upToDate = state, let etag {
                    // Only remember the ETag while up to date: a 304 then still means "nothing new".
                    try? await store.modify(installation) { addons in
                        if let index = addons.firstIndex(where: { $0.id == ref }) { addons[index].etag = etag }
                    }
                }
                addNext()
            }
        }
        return states
    }

    private func updateState(of addon: InstalledAddon, in installation: Installation) async -> (UpdateState, String?) {
        if addon.pinned { return (.pinned, nil) }
        do {
            guard addon.id.source == .github else { return (.failed("Unsupported source"), nil) }
            switch try await github.resolve(addon.id, flavor: installation.flavor, channel: addon.channel, etag: addon.etag) {
            case .notModified:
                return (.upToDate, addon.etag)
            case .release(let release, let etag):
                return addon.isUpdate(release) ? (.available(release), nil) : (.upToDate, etag)
            }
        } catch AddonError.noCompatibleRelease {
            return (.noCompatibleRelease, nil)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
    }

    /// Updates `refs`, or every unpinned add-on when `refs` is empty.
    public nonisolated func update(_ refs: [AddonRef], in installation: Installation) -> AsyncStream<OperationEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.performUpdates(refs, in: installation, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performUpdates(_ refs: [AddonRef], in installation: Installation, continuation: AsyncStream<OperationEvent>.Continuation) async {
        let installed: [InstalledAddon]
        do {
            installed = try await store.addons(in: installation)
        } catch {
            for ref in refs { continuation.yield(.failed(ref, error.localizedDescription)) }
            return
        }

        let explicit = !refs.isEmpty
        let targets: [AddonRef] = explicit ? refs : installed.map(\.id)
        for ref in targets { continuation.yield(.queued(ref)) }

        await withTaskGroup(of: Void.self) { group in
            var pending = targets[...]
            func addNext() {
                guard let ref = pending.popFirst() else { return }
                let addon = installed.first { $0.id == ref }
                group.addTask { await self.updateOne(ref, addon: addon, in: installation, continuation: continuation) }
            }
            for _ in 0..<Self.maxConcurrentOperations { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    private func updateOne(
        _ ref: AddonRef, addon: InstalledAddon?, in installation: Installation,
        continuation: AsyncStream<OperationEvent>.Continuation
    ) async {
        guard let addon else {
            continuation.yield(.failed(ref, AddonError.notInstalled(ref).localizedDescription))
            return
        }
        if addon.pinned {
            continuation.yield(.skipped(ref, reason: "Pinned"))
            return
        }
        do {
            let release = try await resolve(ref, for: installation, channel: addon.channel)
            guard addon.isUpdate(release) else {
                continuation.yield(.skipped(ref, reason: "Up to date"))
                return
            }
            continuation.yield(.downloading(ref, progress: 0))
            // Download first so progress and the installing phase are reported separately;
            // `install` then reuses the cached archive.
            _ = try await downloader.download(release) { fraction in
                continuation.yield(.downloading(ref, progress: fraction))
            }
            continuation.yield(.installing(ref))
            let updated = try await install(release, into: installation, channel: nil, force: false, pin: nil, progress: { _ in })
            continuation.yield(.done(updated))
        } catch {
            continuation.yield(.failed(ref, error.localizedDescription))
        }
    }

    // MARK: - Remove, rollback, settings

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

    public func rollback(_ ref: AddonRef, in installation: Installation) async throws {
        guard let addon = try await store.addons(in: installation).first(where: { $0.id == ref }) else {
            throw AddonError.notInstalled(ref)
        }
        guard let previous = addon.previousRelease else { throw AddonError.noRollbackAvailable(ref) }

        var release = ResolvedRelease(
            ref: ref, name: addon.name, version: previous.version, releaseID: previous.releaseID,
            publishedAt: previous.publishedAt, downloadURL: URL(filePath: "/"), assetName: previous.assetName,
            changelog: previous.changelog
        )
        let archive = downloader.archiveURL(for: release)
        guard FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)) else {
            throw AddonError.noRollbackAvailable(ref)
        }
        release.downloadURL = archive
        // Pin so the next update doesn't immediately undo the rollback.
        try await install(release, into: installation, channel: nil, force: false, pin: true, progress: { _ in })
    }

    public func setPinned(_ pinned: Bool, for ref: AddonRef, in installation: Installation) async throws {
        try await modifyAddon(ref, in: installation) { $0.pinned = pinned }
    }

    public func setChannel(_ channel: Channel, for ref: AddonRef, in installation: Installation) async throws {
        try await modifyAddon(ref, in: installation) {
            $0.channel = channel
            $0.etag = nil
        }
    }

    private func modifyAddon(_ ref: AddonRef, in installation: Installation, _ change: @escaping @Sendable (inout InstalledAddon) -> Void) async throws {
        try await store.modify(installation) { addons in
            guard let index = addons.firstIndex(where: { $0.id == ref }) else { throw AddonError.notInstalled(ref) }
            change(&addons[index])
        }
    }

    // MARK: - Maintenance

    /// Deletes downloaded archives, the catalogue cache and cached support checks.
    public func clearCaches() async throws {
        await supportCache.removeAll()
        let fm = FileManager.default
        if fm.fileExists(atPath: directories.caches.path(percentEncoded: false)) {
            for item in try fm.contentsOfDirectory(at: directories.caches, includingPropertiesForKeys: nil) {
                try fm.removeItem(at: item)
            }
        }
    }
}
