import Foundation

/// Update checks, updates, rollback, pinning and channels (docs/features/installing.md).
extension AddonManager {
    /// An explicit check (⌘R, `addonctl outdated`): always asks for the latest tags.
    public func checkForUpdates(in installation: Installation) async throws -> [AddonRef: UpdateState] {
        try await checkForUpdates(in: installation, policy: .forceRevalidate, progress: { _, _ in })
    }

    /// `progress` is called once per add-on as its check lands, with the number done so far.
    /// The background refresh passes `.revalidateIfStale`; explicit checks `.forceRevalidate`.
    /// Either way this is a bulk check: add-ons only the API can decide reuse their last
    /// state while their API check isn't due (`LatestReleaseStore.apiCheckIsDue`). The states
    /// are stored for that.
    func checkForUpdates(
        in installation: Installation, policy: CachePolicy, background: Bool = false,
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
        of addon: InstalledAddon, in installation: Installation, policy: CachePolicy, background: Bool = false,
        previous: UpdateState? = nil
    ) async -> (UpdateState, String?) {
        if addon.pinned { return (.pinned, nil) }
        let own = installation.flavor
        // An add-on installed as another game's build (the Retail build on Forever) keeps to
        // that build; it never switches unless the user chose it.
        let build = addon.installedFlavorBuild ?? own
        func marked(_ release: ResolvedRelease) -> ResolvedRelease {
            var release = release
            release.flavorBuild = build == own ? nil : build
            return release
        }
        do {
            guard addon.id.source == .github else { return (.failed("Unsupported source"), nil) }
            // Stable channel: the latest release (the same lookup support checks use) settles
            // most add-ons. An unchanged tag is up to date, with no release.json needed; a new
            // tag whose release.json has the flavor is the update. Only when neither decides
            // (no release.json, the new release lacks the flavor, or the lookup failed) is the
            // API asked. Prereleases always need the API.
            if addon.channel == .stable {
                // On a fallback build, a build for the installation's own flavor is the update
                // ("Forever build available"), whatever its tag.
                if build != own {
                    var latest = await github.latest.latestRelease(for: addon.id, flavor: own, policy: policy, background: background)
                    if !latest.failed, case .supported = latest.status {
                        latest = await github.latest.withBuild(latest, ref: addon.id, flavor: own, fetch: true, background: background)
                        if let release = await github.latest.resolvedRelease(addon.id, from: latest, flavor: own) { return (.available(release), nil) }
                    }
                }
                var latest = await github.latest.latestRelease(for: addon.id, flavor: build, policy: policy, background: background)
                if !latest.failed, latest.status != .unknown, let tag = latest.tag {
                    if tag == addon.version { return (.upToDate, addon.etag) }
                    latest = await github.latest.withBuild(latest, ref: addon.id, flavor: build, fetch: true, background: background)
                    if let release = await github.latest.resolvedRelease(addon.id, from: latest, flavor: build).map(marked) {
                        return addon.isUpdate(release) ? (.available(release), nil) : (.upToDate, addon.etag)
                    }
                }
            }
            if let previous, let reused = Self.reusable(previous, for: addon), !(await github.latest.apiCheckIsDue(for: addon.id)) {
                return reused
            }
            switch try await github.source.resolve(addon.id, flavor: build, channel: addon.channel, etag: addon.etag) {
            case .notModified:
                return (.upToDate, addon.etag)
            case .release(let release, let etag):
                let release = marked(release)
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

    public func rollback(_ ref: AddonRef, in installation: Installation) async throws {
        guard let addon = try await store.addons(in: installation).first(where: { $0.id == ref }) else {
            throw AddonError.notInstalled(ref)
        }
        guard let previous = addon.previousRelease else { throw AddonError.noRollbackAvailable(ref) }

        var release = ResolvedRelease(
            ref: ref, name: addon.name, version: previous.version, releaseID: previous.releaseID,
            publishedAt: previous.publishedAt, downloadURL: URL(filePath: "/"), assetName: previous.assetName,
            changelog: previous.changelog, flavorBuild: previous.flavorBuild
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
}
