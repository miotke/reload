import Foundation

/// The real `AddonManaging` implementation, shared by the app and `addonctl` (docs/architecture/core.md).
public actor AddonManager: AddonManaging {
    public nonisolated let directories: AppDirectories
    public nonisolated let store: InstallStore

    let http: any HTTPClient
    let locator: InstallationLocator
    let installer: Installer
    let downloader: Downloader
    let keychain: KeychainStore
    let environment: [String: String]
    /// Catalogue, support verdicts, details and refresh state (docs/architecture/core.md).
    public nonisolated let database: MetadataDatabase
    let catalogue: CatalogueSource
    let supportCache: SupportCache
    /// Used only for `parse`, which never touches the network or the token.
    let parser: GitHubSource

    let github: GitHubSource
    let githubSearch: GitHubSearchProvider
    let searchCoordinator: SearchCoordinator
    /// Automatic detection runs at most once per process; later scans are explicit.
    private var didAutoDetect = false
    var now: @Sendable () -> Date = Date.init

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
        let downloader = Downloader(cachesDirectory: directories.caches, transport: downloadTransport)
        self.downloader = downloader
        // If the file can't be opened (disk full, permissions), work from memory this session.
        let database = (try? MetadataDatabase(directories: directories)) ?? (try! MetadataDatabase.inMemory())
        self.database = database
        self.catalogue = CatalogueSource(http: http, database: database)
        let supportCache = SupportCache(database: database)
        self.supportCache = supportCache
        self.parser = GitHubSource(http: http)

        // The Keychain is read on first GitHub use, not here: init runs on the main thread at
        // launch and a Keychain prompt would block it.
        let tokenProvider: @Sendable () -> String? = { Self.token(environment: environment, keychain: keychain) }
        self.github = GitHubSource(
            http: http, cacheDirectory: directories.caches, database: database, store: supportCache, tokenProvider: tokenProvider,
            archiveURL: { downloader.archiveURL(for: $0) }
        )
        self.githubSearch = GitHubSearchProvider(http: http, database: database, tokenProvider: tokenProvider)
        self.searchCoordinator = SearchCoordinator(catalogue: catalogue, github: githubSearch, supportCache: supportCache)
    }

    /// `ADDONS_GITHUB_TOKEN`, then `GITHUB_TOKEN`, then the Keychain (docs/architecture/core.md).
    static func token(environment: [String: String], keychain: KeychainStore) -> String? {
        for key in ["ADDONS_GITHUB_TOKEN", "GITHUB_TOKEN"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return keychain.get()
    }

    /// Picks up a new token, keeping ETags, cached release.json files and rate-limit state.
    public func tokenDidChange() async {
        let token = Self.token(environment: environment, keychain: keychain)
        await github.setToken(token)
        await githubSearch.setToken(token)
    }

    /// Tests skip the backoff sleeps between github.com retries.
    func setRetryDelay(_ delay: @escaping @Sendable (Int, TimeInterval?) -> Duration) async {
        await github.setRetryDelay(delay)
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) async {
        now = clock
        await github.setClock(clock)
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

    /// Reconciles the store with disk, then suggests repos for unmanaged folders from the
    /// local catalogue and groups the folders one release covers. No network.
    public func addons(in installation: Installation) async throws -> [AddonStatus] {
        let statuses = try await store.reconcile(installation)
        let unmanaged = statuses.compactMap(\.unmanagedFolder)
        guard !unmanaged.isEmpty else { return statuses }
        let index = await catalogue.adoptionIndex()
        let grouped = AdoptionIndex.group(unmanaged.map(index.suggesting), releaseFolders: await database.releaseFolders())
        return statuses.filter { $0.unmanagedFolder == nil } + grouped.map(AddonStatus.unmanaged)
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

    /// Reconciles the installation with disk first; pass `installed` to skip that per query.
    public nonisolated func search(_ query: SearchQuery, in installation: Installation) -> AsyncStream<[SearchResult]> {
        AsyncStream { continuation in
            let task = Task {
                let installed = (try? await self.addons(in: installation)) ?? []
                for await results in self.searchCoordinator.search(query, installed: installed) {
                    continuation.yield(results)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Search with the caller's current add-on list, so typing doesn't rescan `AddOns/`.
    public nonisolated func search(_ query: SearchQuery, in installation: Installation, installed: [AddonStatus]) -> AsyncStream<[SearchResult]> {
        searchCoordinator.search(query, installed: installed)
    }

    /// Like `search(_:in:installed:)`, but also reports when a GitHub live search is running.
    public nonisolated func searchUpdates(_ query: SearchQuery, in installation: Installation, installed: [AddonStatus]) -> AsyncStream<SearchUpdate> {
        searchCoordinator.searchUpdates(query, installed: installed)
    }

    /// The stored catalogue row for `ref` (including repos found by live search). Local only.
    public func catalogueEntry(for ref: AddonRef) async -> CatalogueEntry? {
        await catalogue.entry(for: ref)
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

    /// Stable channel: tries the quota-free route first (latest tag + release.json), and
    /// uses the API only when that can't decide.
    public func resolve(_ ref: AddonRef, for installation: Installation, channel: Channel) async throws -> ResolvedRelease {
        guard ref.source == .github else { throw AddonError.invalidReference(ref.description) }
        if channel == .stable, let release = await github.quotaFreeResolve(ref, flavor: installation.flavor, policy: .forceRevalidate) {
            return release
        }
        return try await resolve(ref, for: installation, channel: channel, etag: nil).release
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
        // Extraction is the slow part; it runs before the lock the CLI and app wait on, and
        // off this actor. Only the ownership check, the swap and the store write are locked.
        let prepared = try await Self.prepare(installer, archive: archive, into: installation)
        await database.setReleaseFolders(prepared.folders, tag: release.version, for: release.ref.identifier, at: now())
        do {
            return try await store.withLock { store in
                let current = try store.addons(in: installation)
                let previous = current.first { $0.id == release.ref }
                var addon = try installer.commit(prepared, release: release, current: current, force: force)
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
        } catch {
            // `commit` cleans up after itself; this covers failures before it ran.
            prepared.discard()
            throw error
        }
    }

    @concurrent
    private static func prepare(_ installer: Installer, archive: URL, into installation: Installation) async throws -> Installer.PreparedInstall {
        try installer.prepare(archive: archive, into: installation)
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
        await database.setReleaseFolders(shipped, tag: release.version, for: ref.identifier, at: now())

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

    // MARK: - Updates

    /// An explicit check (⌘R, `addonctl outdated`): always asks for the latest tags.
    public func checkForUpdates(in installation: Installation) async throws -> [AddonRef: UpdateState] {
        try await checkForUpdates(in: installation, policy: .forceRevalidate, progress: { _, _ in })
    }

    /// `progress` is called once per add-on as its check lands, with the number done so far.
    /// The background refresh passes `.revalidateIfStale`; explicit checks `.forceRevalidate`.
    /// Either way this is a bulk check: add-ons only the API can decide reuse their last
    /// state while their API check isn't due (`GitHubSource.apiCheckIsDue`). The states
    /// are stored for that.
    func checkForUpdates(
        in installation: Installation, policy: GitHubSource.CachePolicy, background: Bool = false,
        progress: @Sendable (InstalledAddon, Int) -> Void
    ) async throws -> [AddonRef: UpdateState] {
        let addons = try await store.addons(in: installation)
        let previous = await storedUpdates(in: installation)
        var states: [AddonRef: UpdateState] = [:]
        var etags: [AddonRef: String] = [:]

        try await withThrowingTaskGroup(of: (InstalledAddon, UpdateState, String?).self) { group in
            var pending = addons[...]
            func addNext() {
                guard let addon = pending.popFirst() else { return }
                let last = previous[addon.id]
                group.addTask {
                    let (state, etag) = await self.updateState(of: addon, in: installation, policy: policy, background: background, previous: last)
                    return (addon, state, etag)
                }
            }
            for _ in 0..<Self.maxConcurrentOperations { addNext() }
            while let (addon, state, etag) = try await group.next() {
                states[addon.id] = state
                // Only remember the ETag while up to date: a 304 then still means "nothing new".
                if case .upToDate = state, let etag, etag != addon.etag { etags[addon.id] = etag }
                progress(addon, states.count)
                addNext()
            }
        }

        // The app reloads whenever the store changes, so a check that learned nothing new
        // mustn't write.
        if !etags.isEmpty {
            let changes = etags
            try? await store.modify(installation) { addons in
                for index in addons.indices {
                    if let etag = changes[addons[index].id] { addons[index].etag = etag }
                }
            }
        }
        await storeUpdates(states, in: installation)
        return states
    }

    /// Records the states a check found, for the next bulk check and the refresh's skip path.
    /// Writes nothing when they're unchanged.
    func storeUpdates(_ states: [AddonRef: UpdateState], in installation: Installation) async {
        _ = try? await database.execute("""
            INSERT INTO refresh_state(installation_id, updates_json) VALUES (?, ?)
            ON CONFLICT(installation_id) DO UPDATE SET updates_json = excluded.updates_json
            WHERE refresh_state.updates_json IS NOT excluded.updates_json
            """, installation.id, StoredUpdateState.encode(states))
    }

    /// - Parameter previous: the last stored state, from a bulk check. When only the API can
    ///   decide and the repo's API check isn't due, it's returned instead of a request. Nil
    ///   (an explicit single-add-on action) always asks.
    func updateState(
        of addon: InstalledAddon, in installation: Installation, policy: GitHubSource.CachePolicy, background: Bool = false,
        previous: UpdateState? = nil
    ) async -> (UpdateState, String?) {
        if addon.pinned { return (.pinned, nil) }
        do {
            guard addon.id.source == .github else { return (.failed("Unsupported source"), nil) }
            // Stable channel: the latest release (the same lookup support checks use) settles
            // most add-ons. An unchanged tag is up to date, with no release.json needed; a new
            // tag whose release.json has the flavor is the update. Only when neither decides
            // (no release.json, the new release lacks the flavor, or the lookup failed) is the
            // API asked. Prereleases always need the API.
            if addon.channel == .stable {
                var latest = await github.latestRelease(for: addon.id, flavor: installation.flavor, policy: policy, background: background)
                if !latest.failed, latest.status != .unknown, let tag = latest.tag {
                    if tag == addon.version { return (.upToDate, addon.etag) }
                    latest = await github.withBuild(latest, ref: addon.id, flavor: installation.flavor, fetch: true, background: background)
                    if let release = await github.resolvedRelease(addon.id, from: latest, flavor: installation.flavor) {
                        return addon.isUpdate(release) ? (.available(release), nil) : (.upToDate, addon.etag)
                    }
                }
            }
            if let previous, let reused = Self.reusable(previous, for: addon), !(await github.apiCheckIsDue(for: addon.id)) {
                return reused
            }
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

    /// A previous answer still worth showing without asking the API again. Failures are
    /// retried; an available release that's since been installed is up to date.
    private static func reusable(_ state: UpdateState, for addon: InstalledAddon) -> (UpdateState, String?)? {
        switch state {
        case .upToDate: (.upToDate, addon.etag)
        case .noCompatibleRelease: (.noCompatibleRelease, nil)
        case .available(let release): addon.isUpdate(release) ? (.available(release), nil) : (.upToDate, addon.etag)
        case .pinned, .failed: nil
        }
    }


    /// Updates `refs`, or every unpinned add-on when `refs` is empty. Each add-on is checked
    /// first (latest tag, else ETag) and only installed when an update is available, so an
    /// up-to-date add-on costs at most one quota-free request.
    public nonisolated func update(_ refs: [AddonRef], in installation: Installation) -> AsyncStream<OperationEvent> {
        updateStream { manager, continuation in
            await manager.performUpdates(refs, releases: [:], in: installation, continuation: continuation)
        }
    }

    /// Installs already-resolved releases, such as the app's `.available(release)` states,
    /// without resolving them again. Releases that aren't newer than what's installed are skipped.
    public nonisolated func update(releases: [ResolvedRelease], in installation: Installation) -> AsyncStream<OperationEvent> {
        // Unlike `update([])`, which means "everything", no releases means nothing to do.
        guard !releases.isEmpty else { return AsyncStream { $0.finish() } }
        let byRef = Dictionary(releases.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        return updateStream { manager, continuation in
            await manager.performUpdates(releases.map(\.ref), releases: byRef, in: installation, continuation: continuation)
        }
    }

    private nonisolated func updateStream(
        _ body: @escaping @Sendable (AddonManager, AsyncStream<OperationEvent>.Continuation) async -> Void
    ) -> AsyncStream<OperationEvent> {
        // A slow consumer loses old progress ticks, never the stream's end: progress is
        // already throttled, so the buffer only overflows if the consumer stalls.
        let (stream, continuation) = AsyncStream.makeStream(of: OperationEvent.self, bufferingPolicy: .bufferingNewest(512))
        let task = Task {
            await body(self, continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func performUpdates(
        _ refs: [AddonRef], releases: [AddonRef: ResolvedRelease], in installation: Installation,
        continuation: AsyncStream<OperationEvent>.Continuation
    ) async {
        let installed: [InstalledAddon]
        do {
            installed = try await store.addons(in: installation)
        } catch {
            for ref in refs { continuation.yield(.failed(ref, error.localizedDescription)) }
            return
        }

        let targets: [AddonRef] = refs.isEmpty ? installed.map(\.id) : refs
        for ref in targets { continuation.yield(.queued(ref)) }
        // Updating one add-on always asks; updating many is a bulk check (API throttle).
        let previous = targets.count > 1 ? await storedUpdates(in: installation) : [:]

        await withTaskGroup(of: Void.self) { group in
            var pending = targets[...]
            func addNext() {
                guard let ref = pending.popFirst() else { return }
                let addon = installed.first { $0.id == ref }
                let release = releases[ref]
                let last = previous[ref]
                group.addTask {
                    await self.updateOne(ref, addon: addon, release: release, previous: last, in: installation, continuation: continuation)
                }
            }
            for _ in 0..<Self.maxConcurrentOperations { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    private func updateOne(
        _ ref: AddonRef, addon: InstalledAddon?, release given: ResolvedRelease?, previous: UpdateState?,
        in installation: Installation, continuation: AsyncStream<OperationEvent>.Continuation
    ) async {
        guard let addon else {
            continuation.yield(.failed(ref, AddonError.notInstalled(ref).localizedDescription))
            return
        }
        if addon.pinned {
            continuation.yield(.skipped(ref, reason: "Pinned"))
            return
        }
        let release: ResolvedRelease
        if let given {
            guard addon.isUpdate(given) else {
                continuation.yield(.skipped(ref, reason: "Up to date"))
                return
            }
            release = given
        } else {
            switch await updateState(of: addon, in: installation, policy: .forceRevalidate, previous: previous).0 {
            case .available(let found):
                release = found
            case .upToDate, .pinned:
                continuation.yield(.skipped(ref, reason: "Up to date"))
                return
            case .noCompatibleRelease:
                continuation.yield(.failed(ref, AddonError.noCompatibleRelease(ref, installation.flavor).localizedDescription))
                return
            case .failed(let message):
                continuation.yield(.failed(ref, message))
                return
            }
        }
        do {
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
