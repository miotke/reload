import Foundation

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

/// Resolves add-ons published as GitHub Releases (docs/features/release-selection.md).
///
/// - API calls go to `api.github.com` and count against the rate limit. release.json and zip
///   downloads, the `releases/latest` redirect and raw.githubusercontent.com don't.
/// - The rate-limit state is exposed via `rateLimit()` and, with a database, shared with
///   other processes. No API request is made while it says the quota is used up.
/// - Support verdicts and latest tags have one owner: `latestRelease`/`check` read and write
///   them in `store`, and decide by a `CachePolicy` whether to go to the network.
public actor GitHubSource: Source, SupportChecking {
    public nonisolated let id: SourceID = .github

    /// `apiSupport(for:flavor:)` returns `.unknown` instead of calling the API when this few calls remain.
    public static let supportReserve = 10
    /// Releases without release.json whose zips are downloaded before giving up.
    public static let maxInspectedReleases = 3
    /// Zips inspected per release without release.json.
    public static let maxCandidatesPerRelease = 2
    /// Optional API calls (README fallback, release details) are only made above this many.
    public static let comfortableQuota = 30
    /// Retries of a github.com request after a 429 or 5xx.
    static let maxWebRetries = 2
    /// Repos whose last releases response is kept in memory for ETag revalidation.
    static let releasesCacheLimit = 64

    static let apiBase = URL(string: "https://api.github.com")!
    static let webBase = URL(string: "https://github.com")!

    /// Stored support verdicts and latest tags. `check` is the only writer of verdicts.
    public nonisolated let store: SupportCache

    private let http: HTTPClient
    private var token: String?
    /// Resolves the token on first API use, so creating a source never waits on the Keychain.
    private var tokenProvider: (@Sendable () -> String?)?
    private let cacheDirectory: URL?
    private let database: MetadataDatabase?
    /// Where inspected zips are kept: the `Downloader`'s archive path, so an install reuses them.
    private let archiveURL: (@Sendable (ResolvedRelease) -> URL)?
    var now: @Sendable () -> Date = { Date() }

    private var rateRemaining: Int?
    private var rateReset: Date?
    private var loadedRateLimit = false
    /// Decoded release.json files by asset id. Assets are immutable, so these never expire.
    private var releaseJSONCache: [Int64: ReleaseJSON] = [:]
    /// Last 200 response of the releases endpoint per repo (lowercased `owner/repo`), capped
    /// at `releasesCacheLimit` with the least recently stored dropped first.
    private var releasesCache: [String: (etag: String, releases: [GitHubRelease])] = [:]
    private var releasesCacheOrder: [String] = []
    /// release.json by lowercased `owner/repo@tag` (nil: that release has none), in front of
    /// the `release_json` table.
    private var tagReleaseJSON: [String: ReleaseJSON?] = [:]
    /// Latest-release lookups in flight, so two callers asking at once share one request.
    private var inFlightLatest: [String: Task<LatestRelease, Never>] = [:]
    /// Set after github.com keeps refusing; web requests fail fast until then.
    private var webBlockedUntil: Date?
    /// Delay before retry `attempt` (1-based), given the server's `Retry-After` if any.
    var retryDelay: @Sendable (_ attempt: Int, _ retryAfter: TimeInterval?) -> Duration = { attempt, retryAfter in
        // Jitter keeps concurrent checks from retrying in lockstep.
        .seconds(retryAfter ?? (Double(1 << attempt) + Double.random(in: 0..<0.5)))
    }

    public init(http: HTTPClient = URLSessionHTTPClient(), token: String? = nil, cacheDirectory: URL? = nil) {
        self.init(http: http, token: token, cacheDirectory: cacheDirectory, database: nil)
    }

    /// - Parameters:
    ///   - database: shares the API rate-limit state with other processes and holds the
    ///     support verdicts (an in-memory database is used without one).
    ///   - store: the `SupportCache` to own; by default one over `database`.
    ///   - tokenProvider: read once, on the first API call, when `token` is nil.
    ///   - archiveURL: where to keep inspected zips (`Downloader.archiveURL(for:)`).
    public init(
        http: HTTPClient = URLSessionHTTPClient(), token: String? = nil, cacheDirectory: URL? = nil,
        database: MetadataDatabase?, store: SupportCache? = nil, tokenProvider: (@Sendable () -> String?)? = nil,
        archiveURL: (@Sendable (ResolvedRelease) -> URL)? = nil
    ) {
        self.http = http
        self.token = Self.clean(token)
        self.tokenProvider = token == nil ? tokenProvider : nil
        self.cacheDirectory = cacheDirectory
        self.database = database
        self.store = store ?? SupportCache(database: database ?? (try! MetadataDatabase.inMemory()))
        self.archiveURL = archiveURL
    }

    private static func clean(_ token: String?) -> String? {
        token.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Replaces the token, keeping caches and ETags.
    public func setToken(_ token: String?) {
        self.token = Self.clean(token)
        tokenProvider = nil
        // Another account has its own quota; the next response says how much.
        rateRemaining = nil
        rateReset = nil
        loadedRateLimit = true
    }

    /// True when a token is configured (resolving a lazy one).
    public func hasToken() -> Bool {
        currentToken() != nil
    }

    private func currentToken() -> String? {
        if let tokenProvider {
            token = Self.clean(tokenProvider())
            self.tokenProvider = nil
        }
        return token
    }

    /// Latest rate-limit state seen in any API response, here or (through the database)
    /// in another process.
    public func rateLimit() async -> (remaining: Int?, resetAt: Date?) {
        await loadRateLimitIfNeeded()
        return (rateRemaining, rateReset)
    }

    private func loadRateLimitIfNeeded() async {
        guard !loadedRateLimit else { return }
        loadedRateLimit = true
        guard rateRemaining == nil, let state = await database?.rateLimit("core") else { return }
        rateRemaining = state.remaining
        rateReset = state.resetAt
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) async {
        now = clock
        await store.setClock(clock)
    }

    func setRetryDelay(_ delay: @escaping @Sendable (Int, TimeInterval?) -> Duration) {
        retryDelay = delay
    }

    /// True when optional API calls won't eat into what installs and updates need.
    /// Unknown counts as comfortable: nothing has been spent yet.
    public func quotaIsComfortable() async -> Bool {
        await loadRateLimitIfNeeded()
        guard let rateRemaining else { return true }
        if let rateReset, rateReset <= now() { return true }
        return rateRemaining > Self.comfortableQuota
    }

    // MARK: - Parsing

    /// Accepts `owner/repo`, `github:owner/repo` and `github.com` URLs (with `.git`, a trailing
    /// slash, or `/releases…`, `/tags`, `/tree/…`, `/blob/…` after the repo).
    public nonisolated func parse(_ input: String) -> AddonRef? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        var parts: [Substring]
        if text.lowercased().hasPrefix("github:") {
            text.removeFirst("github:".count)
            parts = text.split(separator: "/", omittingEmptySubsequences: false)
            if parts.last == "" { parts.removeLast() }
            guard parts.count == 2 else { return nil }
        } else if text.contains("://") || text.lowercased().hasPrefix("github.com/") || text.lowercased().hasPrefix("www.github.com/") {
            if !text.contains("://") { text = "https://" + text }
            guard let components = URLComponents(string: text),
                  let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = components.host?.lowercased(), host == "github.com" || host == "www.github.com"
            else { return nil }
            parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return nil }
            if parts.count > 2 {
                let allowed = ["releases", "tags", "tree", "blob"]
                guard allowed.contains(parts[2].lowercased()) else { return nil }
            }
            parts = Array(parts.prefix(2))
        } else {
            parts = text.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 3, parts.last == "" { parts.removeLast() }
            guard parts.count == 2 else { return nil }
        }
        let owner = String(parts[0])
        var repo = String(parts[1])
        if repo.lowercased().hasSuffix(".git") { repo.removeLast(4) }
        guard Self.isValidOwner(owner), Self.isValidRepo(repo) else { return nil }
        return AddonRef(source: .github, identifier: "\(owner)/\(repo)")
    }

    static func isValidOwner(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$"#, options: .regularExpression) != nil
    }

    static func isValidRepo(_ s: String) -> Bool {
        s != "." && s != ".." && s.range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil
    }

    // MARK: - Resolve

    public func resolve(_ ref: AddonRef, flavor: Flavor, channel: Channel, etag: String?) async throws -> ResolveResult {
        let (owner, repo) = try Self.split(ref)
        let key = Self.cacheKey(ref)
        let cached = releasesCache[key]
        let releases: [GitHubRelease]
        let responseETag: String?
        switch try await fetchReleases(ref, owner: owner, repo: repo, etag: etag ?? cached?.etag) {
        case .notModified:
            if etag != nil { return .notModified }
            // 304 against our own cached ETag: reuse the cached releases.
            guard let cached else { return .notModified }
            releases = cached.releases
            responseETag = cached.etag
        case .releases(let list, let tag):
            releases = list
            responseETag = tag
        }

        switch try await select(ref: ref, releases: releases, flavor: flavor, channel: channel, downloadZips: true) {
        case .selected(let release, let asset, let reasoning):
            let entryName = release.releaseJSONAsset
                .flatMap { releaseJSONCache[$0.id] }?
                .release(for: flavor)?.name
            let resolved = ResolvedRelease(
                ref: ref,
                name: entryName ?? repo,
                version: release.tagName,
                releaseID: release.id,
                publishedAt: release.publishedAt ?? release.createdAt ?? .distantPast,
                downloadURL: asset.browserDownloadURL,
                assetName: asset.name,
                changelog: release.body,
                isPrerelease: release.prerelease,
                reasoning: reasoning
            )
            return .release(resolved, etag: responseETag)
        case .needsDownload, .none:
            throw AddonError.noCompatibleRelease(ref, flavor)
        }
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

    // MARK: - Latest release and support (the single owner of support state)

    /// How `check` and `latestRelease` may use what's stored before going to the network.
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
        guard ref.source == .github, let (owner, repo) = try? Self.split(ref) else {
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
        let key = Self.cacheKey(ref) + "#" + flavor.rawValue + (shareTags ? "" : "!")
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
            if let tag = try await fetchLatestTag(owner: owner, repo: repo, ref: ref, background: background) {
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
        if !background, !pushedBack, await quotaIsComfortable(), await apiCheckIsDue(for: ref) {
            let status = await apiSupport(for: ref, flavor: flavor)
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

    /// Fills in the flavor's build of a supported answer from the stored release.json, or,
    /// with `fetch`, downloads it once for that tag.
    func withBuild(_ answer: LatestRelease, ref: AddonRef, flavor: Flavor, fetch: Bool, background: Bool = false) async -> LatestRelease {
        guard answer.build == nil, case .supported = answer.status, let tag = answer.tag,
              let (owner, repo) = try? Self.split(ref) else { return answer }
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

    /// The quota-free `ResolvedRelease` for a supported latest release: the asset URL is
    /// `releases/download/<tag>/<filename>`. It has no real release ID or date: `releaseID`
    /// is a negative hash of the tag and `publishedAt` is now. `InstalledAddon.isUpdate`
    /// compares tags for such releases.
    func resolvedRelease(_ ref: AddonRef, from latest: LatestRelease, flavor: Flavor) -> ResolvedRelease? {
        guard let tag = latest.tag, let build = latest.build, let (owner, repo) = try? Self.split(ref) else { return nil }
        let interface = build.metadata.first { flavor.rules.releaseJSONFlavors.contains($0.flavor.lowercased()) }?.interface
        return ResolvedRelease(
            ref: ref,
            name: build.name ?? repo,
            version: tag,
            releaseID: Self.syntheticReleaseID(ref: ref, tag: tag),
            publishedAt: now(),
            downloadURL: Self.releaseDownloadURL(owner: owner, repo: repo, tag: tag, file: build.filename),
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

    /// True while github.com is pushing back and every web request fails fast.
    func webIsPaused() -> Bool {
        webBlockedUntil.map { $0 > now() } ?? false
    }

    /// True when a stored answer for `ref` and `flavor` is within its lifetime, so
    /// `.revalidateIfStale` wouldn't make a request.
    func hasFreshAnswer(for ref: AddonRef, flavor: Flavor) async -> Bool {
        guard let stored = await store.storedSupport(for: ref, flavor: flavor) else { return false }
        return await store.isFresh(stored)
    }

    private static func isRateLimit(_ error: AddonError) -> Bool {
        if case .rateLimited = error { return true }
        return false
    }

    /// Notes of the latest stable release: at most one API call (`releases/latest`), none
    /// if the releases list this process already holds has that tag. Never downloads zips.
    /// Nil when the repo has no releases.
    public func releaseNotes(for ref: AddonRef, tag: String?) async throws -> (version: String, publishedAt: Date?, markdown: String)? {
        let (owner, repo) = try Self.split(ref)
        if let tag, let cached = releasesCache[Self.cacheKey(ref)]?.releases.first(where: { $0.tagName == tag }) {
            return (cached.tagName, cached.publishedAt ?? cached.createdAt, cached.body ?? "")
        }
        let url = Self.apiBase.appending(path: "repos/\(owner)/\(repo)/releases/latest")
        let (data, response) = try await apiGet(url)
        switch response.statusCode {
        case 200..<300:
            guard let release = try? GitHubRelease.decoder.decode(GitHubRelease.self, from: data) else {
                throw AddonError.http(status: response.statusCode, url: url)
            }
            return (release.tagName, release.publishedAt ?? release.createdAt, release.body ?? "")
        case 404:
            return nil
        default:
            throw AddonError.http(status: response.statusCode, url: url)
        }
    }

    /// The older support check over the releases API. It looks past the latest release but
    /// costs one API call per repo, and returns `.unknown` within `supportReserve` of the limit.
    /// Used by `check` only when a foreground github.com check fails, quota is comfortable
    /// and the repo's API check is due.
    public func apiSupport(for ref: AddonRef, flavor: Flavor) async -> SupportStatus {
        guard ref.source == .github, let (owner, repo) = try? Self.split(ref) else { return .unknown }
        let current = now()
        await loadRateLimitIfNeeded()
        if let remaining = rateRemaining, remaining <= Self.supportReserve, rateReset.map({ $0 > current }) ?? true {
            return .unknown
        }
        do {
            let releases = try await cachedReleases(ref, owner: owner, repo: repo)
            if ReleaseSelector.eligible(releases, channel: .stable).isEmpty { return .noReleases }
            switch try await select(ref: ref, releases: releases, flavor: flavor, channel: .stable, downloadZips: false) {
            case .selected(let release, _, _): return .supported(version: release.tagName)
            case .needsDownload: return .needsDownload
            case .none: return .unsupported
            }
        } catch {
            return .unknown
        }
    }

    // MARK: - Quota-free github.com routes

    /// Tag of the latest stable release (drafts and prereleases excluded), read from the
    /// `Location` of `github.com/<repo>/releases/latest` without following it (following
    /// would download the whole release page). Nil when the repo has no releases. Throws
    /// `notFound` for a missing repo. Private: callers go through `latestRelease`.
    private func fetchLatestTag(owner: String, repo: String, ref: AddonRef, background: Bool) async throws -> String? {
        let url = Self.webBase.appending(path: "\(owner)/\(repo)/releases/latest")
        let (_, response) = try await webRequest(url, method: "HEAD", followRedirects: false, background: background)
        switch response.statusCode {
        case 300..<400:
            let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: url) }
            return Self.tag(fromReleaseURL: location)
        case 200..<300:
            // A client that followed the redirect anyway: the final URL carries the tag.
            return Self.tag(fromReleaseURL: response.url)
        case 404:
            throw AddonError.notFound(ref)
        default:
            throw AddonError.http(status: response.statusCode, url: url)
        }
    }

    /// `…/owner/repo/releases/tag/<tag>` → `<tag>`; anything else (a repo without releases
    /// lands on its plain releases page) → nil.
    static func tag(fromReleaseURL url: URL?) -> String? {
        guard let url else { return nil }
        let parts = url.absoluteURL.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[2] == "releases", parts[3] == "tag" else { return nil }
        return parts[4...].joined(separator: "/")
    }

    static func releaseDownloadURL(owner: String, repo: String, tag: String, file: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let escapedTag = tag.addingPercentEncoding(withAllowedCharacters: allowed) ?? tag
        let escapedFile = file.addingPercentEncoding(withAllowedCharacters: allowed) ?? file
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(escapedTag)/\(escapedFile)")!
    }

    /// release.json of `ref`'s release `tag` from memory or the database, without a request:
    /// nil when it was never fetched, `.some(nil)` when that release has none.
    private func knownReleaseJSON(_ ref: AddonRef, tag: String) async -> ReleaseJSON?? {
        let key = "\(Self.cacheKey(ref))@\(tag)"
        if let hit = tagReleaseJSON[key] { return .some(hit) }
        guard let stored = await store.releaseJSON(for: ref, tag: tag) else { return nil }
        tagReleaseJSON[key] = .some(stored)
        return .some(stored)
    }

    /// release.json of the release tagged `tag`, or nil if it has none. Stored by `repo@tag`
    /// (tags are effectively immutable), so each one is downloaded once, not once per process.
    private func webReleaseJSON(owner: String, repo: String, ref: AddonRef, tag: String, background: Bool) async throws -> ReleaseJSON? {
        if let known = await knownReleaseJSON(ref, tag: tag) { return known }
        let url = Self.releaseDownloadURL(owner: owner, repo: repo, tag: tag, file: "release.json")
        let (data, response) = try await webRequest(url, method: "GET", background: background)
        let json: ReleaseJSON?
        switch response.statusCode {
        case 200..<300: json = try ReleaseJSON(data: data)
        case 404: json = nil
        default: throw AddonError.http(status: response.statusCode, url: url)
        }
        tagReleaseJSON["\(Self.cacheKey(ref))@\(tag)"] = .some(json)
        await store.setReleaseJSON(json, for: ref, tag: tag)
        return json
    }


    /// A request to github.com or raw.githubusercontent.com: no token, no API quota.
    ///
    /// Retries 429 and 5xx twice with jittered backoff. A 429, or a 403 with `Retry-After`,
    /// that persists or asks for a long wait pauses every web request until it's over; a
    /// 403 with neither header (a secondary limit) pauses for at least 60 s. `background`
    /// requests stay off constrained (Low Data Mode) networks.
    func webRequest(
        _ url: URL, method: String = "GET", accept: String? = nil, headers: [String: String] = [:],
        followRedirects: Bool = true, background: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            if let until = webBlockedUntil, until > now() { throw AddonError.rateLimited(resetAt: until) }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
            if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.allowsConstrainedNetworkAccess = !background
            let (data, response) = try await http.data(for: request, followRedirects: followRedirects)
            let status = response.statusCode
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }

            if status == 403, url.host() == "github.com" {
                let until = now().addingTimeInterval(max(retryAfter ?? 60, 60))
                webBlockedUntil = until
                throw AddonError.rateLimited(resetAt: until)
            }
            guard status == 429 || (500...599).contains(status) else { return (data, response) }

            attempt += 1
            if attempt > Self.maxWebRetries || (retryAfter ?? 0) > 30 {
                guard status == 429 else { throw AddonError.http(status: status, url: url) }
                let until = now().addingTimeInterval(retryAfter ?? 60)
                webBlockedUntil = until
                throw AddonError.rateLimited(resetAt: until)
            }
            try await Task.sleep(for: retryDelay(attempt, retryAfter))
        }
    }

    /// GET from the API with the usual headers; used for the README fallback.
    func apiGet(_ url: URL, accept: String = "application/vnd.github+json") async throws -> (Data, HTTPURLResponse) {
        try await checkQuota()
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if let token = currentToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await http.data(for: request)
        await trackRateLimit(response)
        if response.statusCode == 403 || response.statusCode == 429 { throw await apiError(response, data: data, url: url) }
        return (data, response)
    }

    // MARK: - README

    public enum ReadmeResult: Sendable, Hashable {
        /// `etag` and `path` are what to send next time.
        case found(markdown: String, path: String, etag: String?)
        /// The stored copy at `knownPath` is still current.
        case notModified
        /// The repo has no README anywhere we look.
        case none
    }

    /// Where GitHub looks for a README, most common first. `HEAD` on raw.githubusercontent.com
    /// is the default branch, which the catalogue doesn't tell us.
    public static let readmeCandidates = [
        "README.md", ".github/README.md", "readme.md", "Readme.md", "docs/README.md",
        "README.markdown", "README.MD", "README",
    ]
    /// Longer READMEs are cut at a line break below this size.
    public static let maxReadmeBytes = 512 * 1024

    /// The README of `ref`, quota-free from raw.githubusercontent.com. A known path is tried
    /// first (with its ETag, so an unchanged README is a 304). Only with a token, and only
    /// when every candidate 404s, is the API's `/readme` asked (1 call).
    public func readme(for ref: AddonRef, knownPath: String? = nil, etag: String? = nil) async throws -> ReadmeResult {
        let (owner, repo) = try Self.split(ref)
        var candidates = Self.readmeCandidates
        if let knownPath, !knownPath.isEmpty {
            candidates.removeAll { $0 == knownPath }
            candidates.insert(knownPath, at: 0)
        }
        for path in candidates {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(encoded)")!
            var headers: [String: String] = [:]
            if path == knownPath, let etag { headers["If-None-Match"] = etag }
            let (data, response) = try await webRequest(url, headers: headers)
            switch response.statusCode {
            case 304:
                return .notModified
            case 200..<300:
                return .found(markdown: Self.capped(data), path: path, etag: response.value(forHTTPHeaderField: "ETag"))
            case 404:
                continue
            default:
                throw AddonError.http(status: response.statusCode, url: url)
            }
        }
        guard hasToken(), await quotaIsComfortable() else { return .none }
        struct Readme: Decodable { var path: String; var content: String?; var encoding: String? }
        let url = Self.apiBase.appending(path: "repos/\(owner)/\(repo)/readme")
        let (data, response) = try await apiGet(url)
        guard response.statusCode == 200, let readme = try? JSONDecoder().decode(Readme.self, from: data),
              let content = readme.content, readme.encoding == "base64",
              let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return .none }
        return .found(markdown: Self.capped(decoded), path: readme.path, etag: nil)
    }

    static func capped(_ data: Data) -> String {
        guard data.count > maxReadmeBytes else { return String(decoding: data, as: UTF8.self) }
        var cut = data.prefix(maxReadmeBytes)
        if let newline = cut.lastIndex(of: UInt8(ascii: "\n")) { cut = cut[..<newline] }
        return String(decoding: cut, as: UTF8.self)
    }

    /// Releases for `ref`, revalidating the in-memory copy with its ETag.
    private func cachedReleases(_ ref: AddonRef, owner: String, repo: String) async throws -> [GitHubRelease] {
        let key = Self.cacheKey(ref)
        let cached = releasesCache[key]
        switch try await fetchReleases(ref, owner: owner, repo: repo, etag: cached?.etag) {
        case .notModified:
            guard let cached else { throw AddonError.http(status: 304, url: Self.releasesURL(owner: owner, repo: repo)) }
            return cached.releases
        case .releases(let list, _):
            return list
        }
    }

    // MARK: - Selection loop

    enum Outcome {
        case selected(GitHubRelease, GitHubAsset, reasoning: [String])
        /// Only zip inspection could decide, and downloads weren't allowed.
        case needsDownload
        case none(reasoning: [String])
    }

    /// Drives `ReleaseSelector`: fetches release.json files it asks for and, when `downloadZips`,
    /// downloads and inspects candidate zips for up to `maxInspectedReleases` releases.
    func select(ref: AddonRef, releases: [GitHubRelease], flavor: Flavor, channel: Channel, downloadZips: Bool) async throws -> Outcome {
        var failedJSON: Set<Int64> = []
        var excluded: Set<Int64> = []
        var notes: [Int64: [String]] = [:]
        var inspected = 0

        func annotate(_ reasoning: [String]) -> [String] {
            var out: [String] = []
            for line in reasoning {
                out.append(line)
                for release in releases where excluded.contains(release.id) && line == "release \(release.label): no \(flavor.rawValue) zip found" {
                    out.append(contentsOf: notes[release.id] ?? [])
                }
            }
            return out
        }

        while true {
            let cache = releaseJSONCache
            let selection = ReleaseSelector.select(releases, channel: channel, flavor: flavor, releaseJSON: { asset in
                if let json = cache[asset.id] { return .available(json) }
                return failedJSON.contains(asset.id) ? .unavailable : .notLoaded
            }, excluding: excluded)

            switch selection {
            case .selected(let release, let asset, let reasoning):
                return .selected(release, asset, reasoning: annotate(reasoning))

            case .none(let reasoning):
                return .none(reasoning: annotate(reasoning))

            case .needsReleaseJSON(_, let asset, _):
                do {
                    releaseJSONCache[asset.id] = try await releaseJSON(for: asset)
                } catch {
                    failedJSON.insert(asset.id)
                }

            case .needsInspection(let release, let candidates, let reasoning):
                guard downloadZips else { return .needsDownload }
                guard inspected < Self.maxInspectedReleases else {
                    return .none(reasoning: annotate(reasoning) + ["stopped after inspecting \(Self.maxInspectedReleases) releases without release.json"])
                }
                inspected += 1
                for candidate in candidates.prefix(Self.maxCandidatesPerRelease) {
                    let result: FlavorSupport
                    do {
                        result = try await inspect(candidate, of: release, ref: ref, flavor: flavor)
                    } catch let error as AddonError {
                        guard case .invalidArchive(let why) = error else { throw error }
                        notes[release.id, default: []].append("\(candidate.name): unreadable (\(why))")
                        continue
                    }
                    if result.isSupported {
                        return .selected(release, candidate, reasoning: annotate(reasoning) + ["inspected \(candidate.name): \(result.detail)"])
                    }
                    notes[release.id, default: []].append("inspected \(candidate.name): \(result.detail)")
                }
                excluded.insert(release.id)
            }
        }
    }

    // MARK: - HTTP

    enum ReleasesResponse {
        case notModified
        case releases([GitHubRelease], etag: String?)
    }

    static func releasesURL(owner: String, repo: String) -> URL {
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        components.path = "/repos/\(owner)/\(repo)/releases"
        components.queryItems = [URLQueryItem(name: "per_page", value: "10")]
        return components.url!
    }

    /// Throws `rateLimited` instead of spending a request the quota doesn't have.
    /// (A 304 still counts against the quota when unauthenticated.)
    private func checkQuota() async throws {
        await loadRateLimitIfNeeded()
        if rateRemaining == 0, let rateReset, rateReset > now() {
            throw AddonError.rateLimited(resetAt: rateReset)
        }
    }

    private func fetchReleases(_ ref: AddonRef, owner: String, repo: String, etag: String?) async throws -> ReleasesResponse {
        try await checkQuota()
        let url = Self.releasesURL(owner: owner, repo: repo)
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if let token = currentToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // ETags are handled here; don't let URLSession's cache answer for us.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await http.data(for: request)
        await trackRateLimit(response)
        if response.statusCode != 403, response.statusCode != 429 {
            await store.setAPIChecked(at: now(), for: ref)
        }
        switch response.statusCode {
        case 304:
            return .notModified
        case 200..<300:
            let releases: [GitHubRelease]
            do {
                releases = try GitHubRelease.decodeList(from: data)
            } catch {
                throw AddonError.http(status: response.statusCode, url: url)
            }
            let newETag = response.value(forHTTPHeaderField: "ETag")
            if let newETag { remember(releases, etag: newETag, key: Self.cacheKey(ref)) }
            return .releases(releases, etag: newETag)
        case 404:
            throw AddonError.notFound(ref)
        default:
            throw await apiError(response, data: data, url: url)
        }
    }

    private func remember(_ releases: [GitHubRelease], etag: String, key: String) {
        if releasesCache[key] == nil { releasesCacheOrder.append(key) }
        releasesCache[key] = (etag, releases)
        while releasesCacheOrder.count > Self.releasesCacheLimit {
            releasesCache[releasesCacheOrder.removeFirst()] = nil
        }
    }

    private func apiError(_ response: HTTPURLResponse, data: Data, url: URL) async -> AddonError {
        let status = response.statusCode
        if status == 403 || status == 429 {
            let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            let secondary = String(decoding: data.prefix(2048), as: UTF8.self).localizedCaseInsensitiveContains("secondary rate limit")
            if remaining == 0 || retryAfter != nil || secondary || status == 429 {
                let reset: Date
                if remaining == 0, let date = Self.resetDate(response) {
                    reset = date
                } else if let retryAfter {
                    reset = now().addingTimeInterval(retryAfter)
                } else {
                    // A secondary limit with neither header still means "wait": at least a minute.
                    reset = now().addingTimeInterval(60)
                }
                rateRemaining = 0
                rateReset = reset
                await database?.setRateLimit("core", RateLimitState(remaining: 0, resetAt: reset), at: now())
                return .rateLimited(resetAt: reset)
            }
        }
        return .http(status: status, url: url)
    }

    private func trackRateLimit(_ response: HTTPURLResponse) async {
        loadedRateLimit = true
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let reset = Self.resetDate(response)
        if let remaining { rateRemaining = remaining }
        if let reset { rateReset = reset }
        if remaining != nil || reset != nil {
            await database?.setRateLimit("core", RateLimitState(remaining: rateRemaining, resetAt: rateReset), at: now())
        }
    }

    private static func resetDate(_ response: HTTPURLResponse) -> Date? {
        response.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .map { Date(timeIntervalSince1970: $0) }
    }

    /// GET a `browser_download_url` (no API quota, no token).
    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw AddonError.http(status: response.statusCode, url: url)
        }
        return data
    }

    // MARK: - release.json

    private func releaseJSON(for asset: GitHubAsset) async throws -> ReleaseJSON {
        if let hit = releaseJSONCache[asset.id] { return hit }
        let file = cacheDirectory?.appending(path: "github/release-json/\(asset.id).json", directoryHint: .notDirectory)
        if let file, let data = try? Data(contentsOf: file), let json = try? ReleaseJSON(data: data) {
            return json
        }
        let data = try await download(asset.browserDownloadURL)
        let json = try ReleaseJSON(data: data)
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return json
    }

    // MARK: - Zip inspection

    /// Inspects `asset`, keeping the zip where the `Downloader` would cache it so installing
    /// the same release reuses it (and the downloader's pruning cleans it up).
    private func inspect(_ asset: GitHubAsset, of release: GitHubRelease, ref: AddonRef, flavor: Flavor) async throws -> FlavorSupport {
        let fm = FileManager.default
        let archive = ResolvedRelease(
            ref: ref, name: ref.identifier, version: release.tagName, releaseID: release.id,
            publishedAt: release.publishedAt ?? .distantPast, downloadURL: asset.browserDownloadURL, assetName: asset.name
        )
        let safeName = asset.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let file = archiveURL?(archive)
            ?? cacheDirectory?.appending(path: "downloads/github/\(asset.id)-\(safeName)", directoryHint: .notDirectory)
        if let file {
            if !Downloader.isUsableFile(file) {
                let data = try await download(asset.browserDownloadURL)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }
            return try ZipInspector.inspect(zipAt: file, flavor: flavor)
        }
        let data = try await download(asset.browserDownloadURL)
        let dir = fm.temporaryDirectory.appending(path: "ForeverAddons-inspect-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let temp = dir.appending(path: "\(asset.id)-\(safeName)", directoryHint: .notDirectory)
        try data.write(to: temp)
        return try ZipInspector.inspect(zipAt: temp, flavor: flavor)
    }

    // MARK: - Helpers

    static func split(_ ref: AddonRef) throws -> (owner: String, repo: String) {
        let parts = ref.identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard ref.source == .github, parts.count == 2,
              isValidOwner(String(parts[0])), isValidRepo(String(parts[1])) else {
            throw AddonError.invalidReference(ref.description)
        }
        return (String(parts[0]), String(parts[1]))
    }

    static func cacheKey(_ ref: AddonRef) -> String {
        ref.identifier.lowercased()
    }
}
