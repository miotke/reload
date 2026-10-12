import Foundation

/// How `LatestReleaseStore.check` and `latestRelease` may use what's stored before going to
/// the network (docs/network/caching.md).
public enum CachePolicy: Sendable, Hashable {
    /// Never touch the network: the stored answer, or `.unknown`.
    case preferStored
    /// Reuse a stored answer within its lifetime (`SupportCache` TTLs), else revalidate.
    case revalidateIfStale
    /// Always ask for the latest tag; a stored verdict for an unchanged tag is still reused.
    case forceRevalidate
}

/// What the latest stable release is and whether it supports a flavor.
public struct LatestRelease: Sendable, Hashable {
    /// Nil when the repo has no releases (or doesn't exist), or nothing is known.
    public var tag: String?
    public var status: SupportStatus
    /// The flavor's build from the release's release.json, when it was needed and found.
    public var build: ReleaseJSON.Release?
    /// The last check failed: `tag` and `status` are the last good answer, if any.
    public var failed = false
    /// Every flavor the release ships, from its release.json or an inspected zip; nil when unknown.
    public var availableFlavors: Set<Flavor>?
}

/// The outcome of a support check.
public struct SupportCheck: Sendable, Hashable {
    public var status: SupportStatus
    /// The latest stable tag seen, when the repo has releases.
    public var tag: String?
    /// Every flavor the latest release ships a build for; nil when not known (no release.json
    /// and no inspected zip, no releases, or never checked).
    public var availableFlavors: Set<Flavor>?

    public var families: Set<GameFamily>? { availableFlavors?.families }
}

/// The single owner of Forever support verdicts, latest tags and available flavors
/// (docs/decisions/0011-single-cache-owner.md). Callers state intent with a `CachePolicy`;
/// this decides whether to go to the network, reads and writes `store` itself, and makes
/// concurrent callers share one request. Quota-free: it asks github.com, and the API only
/// as a foreground fallback.
public actor LatestReleaseStore: SupportChecking {
    /// Stored support verdicts and latest tags. `check` is the only writer of verdicts.
    public nonisolated let store: SupportCache

    private let web: GitHubWebClient
    private let api: GitHubAPIClient
    /// The releases-API check, for the foreground fallback when github.com fails.
    private let source: GitHubSource
    var now: @Sendable () -> Date = { Date() }

    /// release.json by lowercased `owner/repo@tag` (nil: that release has none), in front of
    /// the `release_json` table.
    private var tagReleaseJSON: [String: ReleaseJSON?] = [:]
    /// Latest-release lookups in flight, so two callers asking at once share one request.
    private var inFlightLatest: [String: Task<LatestRelease, Never>] = [:]

    public init(store: SupportCache, web: GitHubWebClient, api: GitHubAPIClient, source: GitHubSource) {
        self.store = store
        self.web = web
        self.api = api
        self.source = source
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) async {
        now = clock
        await store.setClock(clock)
    }

    /// Whether `ref` supports `flavor`, by its latest stable release (docs/features/release-selection.md).
    /// This is the only way support is decided: it reads and writes the stored verdicts and
    /// latest tags itself, so callers never judge freshness.
    public func check(_ ref: AddonRef, flavor: Flavor, policy: CachePolicy = .revalidateIfStale, background: Bool = false) async -> SupportCheck {
        let latest = await latestRelease(for: ref, flavor: flavor, policy: policy, background: background)
        return SupportCheck(status: latest.status, tag: latest.tag, availableFlavors: latest.availableFlavors)
    }

    public func support(for ref: AddonRef, flavor: Flavor) async -> SupportStatus {
        await check(ref, flavor: flavor).status
    }

    /// The shared primitive behind `check`, update checks and quota-free resolves:
    /// 1. A stored answer is used if the policy allows (`.preferStored` always,
    ///    `.revalidateIfStale` within its TTL).
    /// 2. With `.revalidateIfStale`, a latest tag any flavor's check stored within the hour is
    ///    reused (tags don't depend on the flavor), so only its release.json may be needed.
    /// 3. Otherwise `releases/latest` gives the tag (redirect not followed). A stored verdict
    ///    made against the same tag is reused; a new tag means its release.json, which is
    ///    stored by `repo@tag` and so fetched once per tag, not once per process.
    /// 4. The answer is stored. A failure keeps the last good verdict, marks the answer
    ///    `failed`, and isn't retried for 15 minutes.
    ///
    /// Concurrent calls for the same repo and flavor share one request. With `needBuild`,
    /// a supported release's build (for its download URL) is filled in, fetching the
    /// release.json if it isn't stored.
    func latestRelease(
        for ref: AddonRef, flavor: Flavor, policy: CachePolicy, needBuild: Bool = false, background: Bool = false
    ) async -> LatestRelease {
        let answer = await latestVerdict(for: ref, flavor: flavor, policy: policy, needBuild: needBuild, background: background)
        return await withFlavors(answer, ref: ref)
    }

    private func latestVerdict(
        for ref: AddonRef, flavor: Flavor, policy: CachePolicy, needBuild: Bool, background: Bool
    ) async -> LatestRelease {
        guard ref.source == .github, let (owner, repo) = try? GitHubSource.split(ref) else {
            return LatestRelease(tag: nil, status: .unknown)
        }
        let stored = await store.storedSupport(for: ref, flavor: flavor)
        let usable = stored.flatMap { row -> LatestRelease? in
            guard let status = row.status else { return nil }
            return LatestRelease(tag: row.tag, status: status, failed: row.errorAt != nil)
        }
        switch policy {
        case .preferStored:
            return await withBuild(usable ?? LatestRelease(tag: stored?.tag, status: .unknown), ref: ref, flavor: flavor, fetch: false, background: background)
        case .revalidateIfStale:
            if let stored, await store.isFresh(stored) {
                let answer = usable ?? LatestRelease(tag: stored.tag, status: .unknown, failed: stored.errorAt != nil)
                return await withBuild(answer, ref: ref, flavor: flavor, fetch: needBuild, background: background)
            }
        case .forceRevalidate:
            break
        }

        let shareTags = policy == .revalidateIfStale
        let key = GitHubSource.cacheKey(ref) + "#" + flavor.rawValue + (shareTags ? "" : "!")
        let task: Task<LatestRelease, Never>
        if let running = inFlightLatest[key] {
            task = running
        } else {
            task = Task {
                defer { self.inFlightLatest[key] = nil }
                if shareTags, let shared = await self.sharedTagAnswer(ref, owner: owner, repo: repo, flavor: flavor, stored: usable, background: background) {
                    return shared
                }
                return await self.revalidate(ref, owner: owner, repo: repo, flavor: flavor, stored: usable, background: background)
            }
            inFlightLatest[key] = task
        }
        let answer = await task.value
        return await withBuild(answer, ref: ref, flavor: flavor, fetch: needBuild, background: background)
    }

    private func verdict(tag: String, releaseJSON json: ReleaseJSON?, flavor: Flavor) -> LatestRelease {
        guard let json else { return LatestRelease(tag: tag, status: .needsDownload) }
        let build = json.release(for: flavor)
        return LatestRelease(
            tag: tag, status: build != nil ? .supported(version: tag) : .unsupported, build: build,
            availableFlavors: json.availableFlavors)
    }

    /// The answer from a latest tag another flavor's check stored under `sharedTagTTL` ago, or
    /// nil to ask github.com. Stored with that tag's age, so it goes stale when the tag does.
    private func sharedTagAnswer(
        _ ref: AddonRef, owner: String, repo: String, flavor: Flavor, stored: LatestRelease?, background: Bool
    ) async -> LatestRelease? {
        guard let meta = await store.latestTag(for: ref), now().timeIntervalSince(meta.checkedAt) < SupportCache.sharedTagTTL else {
            return nil
        }
        let answer: LatestRelease
        if let tag = meta.tag {
            if let stored, stored.tag == tag, !stored.failed {
                answer = stored
            } else {
                do {
                    answer = verdict(tag: tag, releaseJSON: try await webReleaseJSON(owner: owner, repo: repo, ref: ref, tag: tag, background: background), flavor: flavor)
                } catch {
                    return nil
                }
            }
        } else {
            answer = LatestRelease(tag: nil, status: .noReleases)
        }
        await store.set([SupportRecord(ref: ref, status: answer.status, tag: answer.tag, checkedAt: meta.checkedAt, availableFlavors: answer.availableFlavors)], flavor: flavor)
        return answer
    }

    private func revalidate(
        _ ref: AddonRef, owner: String, repo: String, flavor: Flavor, stored: LatestRelease?, background: Bool
    ) async -> LatestRelease {
        let answer: LatestRelease
        do {
            if let tag = try await web.fetchLatestTag(owner: owner, repo: repo, ref: ref, background: background) {
                if let stored, stored.tag == tag {
                    answer = LatestRelease(tag: tag, status: stored.status)
                } else {
                    answer = verdict(tag: tag, releaseJSON: try await webReleaseJSON(owner: owner, repo: repo, ref: ref, tag: tag, background: background), flavor: flavor)
                }
            } else {
                answer = LatestRelease(tag: nil, status: .noReleases)
            }
        } catch AddonError.notFound {
            answer = LatestRelease(tag: nil, status: .noReleases)
        } catch {
            return await failed(ref, flavor: flavor, error: error, stored: stored, background: background)
        }
        await store.set([SupportRecord(ref: ref, status: answer.status, tag: answer.tag, checkedAt: now(), availableFlavors: answer.availableFlavors)], flavor: flavor)
        return answer
    }

    /// Fills in every flavor the answer's release ships, without a request:
    /// - just read from its release.json, or stored for its tag: that;
    /// - its release.json is stored but the flavors aren't (rows from before migration 5): derived and stored;
    /// - the release has no release.json: an inspected zip's flavors, if any, else nil;
    /// - nothing known for this tag yet: whatever is stored.
    private func withFlavors(_ answer: LatestRelease, ref: AddonRef) async -> LatestRelease {
        guard answer.availableFlavors == nil, ref.source == .github else { return answer }
        if case .noReleases = answer.status { return answer }
        var answer = answer
        let stored = await store.storedFlavors(for: ref)
        guard let tag = answer.tag else {
            answer.availableFlavors = stored?.flavors
            return answer
        }
        if let stored, stored.source == .releaseJSON, stored.tag == tag {
            answer.availableFlavors = stored.flavors
        } else if let known = await knownReleaseJSON(ref, tag: tag) {
            if let json = known {
                answer.availableFlavors = json.availableFlavors
                await store.setAvailableFlavors(json.availableFlavors, tag: tag, source: .releaseJSON, for: ref)
            } else {
                if stored?.source == .releaseJSON { await store.setAvailableFlavors(nil, tag: tag, source: .releaseJSON, for: ref) }
                answer.availableFlavors = stored?.source == .inspection ? stored?.flavors : nil
            }
        } else {
            answer.availableFlavors = stored?.flavors
        }
        return answer
    }

    /// A github.com failure. Only an explicit (foreground) check may fall back to the API,
    /// and only with comfortable quota and no API check of this repo in the last 6 hours.
    /// Otherwise the failure is recorded beside the last good verdict, which is returned.
    private func failed(_ ref: AddonRef, flavor: Flavor, error: any Error, stored: LatestRelease?, background: Bool) async -> LatestRelease {
        // If github.com is pushing back, don't move the load onto the API quota.
        let pushedBack = (error as? AddonError).map(Self.isRateLimit) ?? false
        if !background, !pushedBack, await api.quotaIsComfortable(), await apiCheckIsDue(for: ref) {
            let status = await source.apiSupport(for: ref, flavor: flavor)
            if status != .unknown {
                await store.set([SupportRecord(ref: ref, status: status, tag: stored?.tag, checkedAt: now())], flavor: flavor)
                return LatestRelease(tag: stored?.tag, status: status)
            }
        }
        await store.set([SupportRecord(ref: ref, status: .unknown, checkedAt: now())], flavor: flavor)
        var answer = stored ?? LatestRelease(tag: nil, status: .unknown)
        answer.failed = true
        return answer
    }

    private static func isRateLimit(_ error: AddonError) -> Bool {
        if case .rateLimited = error { return true }
        return false
    }

    /// Fills in the flavor's build of a supported answer from the stored release.json, or,
    /// with `fetch`, downloads it once for that tag.
    func withBuild(_ answer: LatestRelease, ref: AddonRef, flavor: Flavor, fetch: Bool, background: Bool = false) async -> LatestRelease {
        guard answer.build == nil, case .supported = answer.status, let tag = answer.tag,
              let (owner, repo) = try? GitHubSource.split(ref) else { return answer }
        var answer = answer
        if let known = await knownReleaseJSON(ref, tag: tag) {
            answer.build = known?.release(for: flavor)
        } else if fetch {
            let json: ReleaseJSON? = (try? await webReleaseJSON(owner: owner, repo: repo, ref: ref, tag: tag, background: background)) ?? nil
            answer.build = json?.release(for: flavor)
        }
        return answer
    }

    /// True when bulk and background checks may spend an API call on `ref`: none was made in
    /// the last `SupportCache.apiCheckInterval` (6 h), or the latest stable tag (learned free
    /// from github.com) has changed since the last one.
    func apiCheckIsDue(for ref: AddonRef) async -> Bool {
        guard let last = await store.apiCheck(for: ref) else { return true }
        if now().timeIntervalSince(last.at) >= SupportCache.apiCheckInterval { return true }
        let current = await store.latestTag(for: ref)?.tag
        return current != nil && current != last.latestTag
    }

    /// True when a stored answer for `ref` and `flavor` is within its lifetime, so
    /// `.revalidateIfStale` wouldn't make a request.
    func hasFreshAnswer(for ref: AddonRef, flavor: Flavor) async -> Bool {
        guard let stored = await store.storedSupport(for: ref, flavor: flavor) else { return false }
        return await store.isFresh(stored)
    }

    // MARK: - Quota-free resolve

    /// The quota-free `ResolvedRelease` for a supported latest release: the asset URL is
    /// `releases/download/<tag>/<filename>`. It has no real release ID or date: `releaseID`
    /// is a negative hash of the tag and `publishedAt` is now. `InstalledAddon.isUpdate`
    /// compares tags for such releases.
    func resolvedRelease(_ ref: AddonRef, from latest: LatestRelease, flavor: Flavor) -> ResolvedRelease? {
        guard let tag = latest.tag, let build = latest.build, let (owner, repo) = try? GitHubSource.split(ref) else { return nil }
        let interface = build.metadata.first { flavor.rules.releaseJSONFlavors.contains($0.flavor.lowercased()) }?.interface
        return ResolvedRelease(
            ref: ref,
            name: build.name ?? repo,
            version: tag,
            releaseID: Self.syntheticReleaseID(ref: ref, tag: tag),
            publishedAt: now(),
            downloadURL: GitHubWebClient.releaseDownloadURL(owner: owner, repo: repo, tag: tag, file: build.filename),
            assetName: build.filename,
            reasoning: [
                "latest release \(tag) (github.com, no API call)",
                "release.json → \(build.filename) (\(flavor.rawValue)\(interface.map { " \($0)" } ?? ""))",
            ]
        )
    }

    /// Resolves the latest stable release without the API when its release.json names a
    /// build for `flavor`; nil when only the API can decide.
    func quotaFreeResolve(_ ref: AddonRef, flavor: Flavor, policy: CachePolicy, background: Bool = false) async -> ResolvedRelease? {
        let latest = await latestRelease(for: ref, flavor: flavor, policy: policy, needBuild: true, background: background)
        return resolvedRelease(ref, from: latest, flavor: flavor)
    }

    /// A stable negative ID for a release known only by its tag (FNV-1a of `owner/repo@tag`).
    static func syntheticReleaseID(ref: AddonRef, tag: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(ref.identifier.lowercased())@\(tag)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return -Int64(hash & 0x3FFF_FFFF_FFFF_FFFF) - 1
    }

    // MARK: - release.json by tag

    /// release.json of `ref`'s release `tag` from memory or the database, without a request:
    /// nil when it was never fetched, `.some(nil)` when that release has none.
    private func knownReleaseJSON(_ ref: AddonRef, tag: String) async -> ReleaseJSON?? {
        let key = "\(GitHubSource.cacheKey(ref))@\(tag)"
        if let hit = tagReleaseJSON[key] { return .some(hit) }
        guard let stored = await store.releaseJSON(for: ref, tag: tag) else { return nil }
        tagReleaseJSON[key] = .some(stored)
        return .some(stored)
    }

    /// release.json of the release tagged `tag`, or nil if it has none. Stored by `repo@tag`
    /// (tags are effectively immutable), so each one is downloaded once, not once per process.
    private func webReleaseJSON(owner: String, repo: String, ref: AddonRef, tag: String, background: Bool) async throws -> ReleaseJSON? {
        if let known = await knownReleaseJSON(ref, tag: tag) { return known }
        let json = try await web.fetchReleaseJSON(owner: owner, repo: repo, tag: tag, background: background)
        tagReleaseJSON["\(GitHubSource.cacheKey(ref))@\(tag)"] = .some(json)
        await store.setReleaseJSON(json, for: ref, tag: tag)
        return json
    }
}
