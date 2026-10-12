import Foundation

/// The outcome of a quota-free support check.
public struct SupportCheck: Sendable, Hashable {
    public var status: SupportStatus
    /// The latest stable tag seen, when the repo has releases.
    public var tag: String?
    /// True when the repo answered "no releases" or "not found"; stored as a negative result.
    public var isNegative: Bool {
        status == .noReleases
    }
}

/// Resolves add-ons published as GitHub Releases (docs/github-source.md).
///
/// - API calls go to `api.github.com` and count against the rate limit. release.json and zip
///   downloads, the `releases/latest` redirect and raw.githubusercontent.com don't.
/// - The rate-limit state is exposed via `rateLimit()` and, with a database, shared with
///   other processes. No API request is made while it says the quota is used up.
public actor GitHubSource: Source, SupportChecking {
    public nonisolated let id: SourceID = .github

    /// `apiSupport(for:flavor:)` returns `.unknown` instead of calling the API when this few calls remain.
    public static let supportReserve = 10
    /// How long a support answer is reused in memory without any request.
    public static let supportTTL: TimeInterval = 6 * 60 * 60
    /// Releases without release.json whose zips are downloaded before giving up.
    public static let maxInspectedReleases = 3
    /// Zips inspected per release without release.json.
    public static let maxCandidatesPerRelease = 2
    /// Optional API calls (README fallback, release details) are only made above this many.
    public static let comfortableQuota = 30
    /// How long a `latestTag(for:)` answer is reused, so a refresh's update and support
    /// phases share one request per repo.
    public static let latestTagTTL: TimeInterval = 10 * 60
    /// Retries of a github.com request after a 429 or 5xx.
    static let maxWebRetries = 2
    /// Repos whose last releases response is kept in memory for ETag revalidation.
    static let releasesCacheLimit = 64
    /// A failed support check isn't repeated for this long.
    static let errorTTL: TimeInterval = 15 * 60

    static let apiBase = URL(string: "https://api.github.com")!
    static let webBase = URL(string: "https://github.com")!

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
    private var supportCache: [String: (check: SupportCheck, checkedAt: Date)] = [:]
    private var latestTags: [String: (tag: String?, checkedAt: Date)] = [:]
    /// release.json by `owner/repo@tag` (nil: that release has none).
    private var tagReleaseJSON: [String: ReleaseJSON?] = [:]
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
    ///   - database: shares the API rate-limit state with other processes and supplies stored
    ///     verdicts, so a support check whose latest tag hasn't changed costs one request.
    ///   - tokenProvider: read once, on the first API call, when `token` is nil.
    ///   - archiveURL: where to keep inspected zips (`Downloader.archiveURL(for:)`).
    public init(
        http: HTTPClient = URLSessionHTTPClient(), token: String? = nil, cacheDirectory: URL? = nil,
        database: MetadataDatabase?, tokenProvider: (@Sendable () -> String?)? = nil,
        archiveURL: (@Sendable (ResolvedRelease) -> URL)? = nil
    ) {
        self.http = http
        self.token = Self.clean(token)
        self.tokenProvider = token == nil ? tokenProvider : nil
        self.cacheDirectory = cacheDirectory
        self.database = database
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

    func setClock(_ clock: @escaping @Sendable () -> Date) {
        now = clock
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

    /// Resolves the latest stable release without the API, when its release.json names a
    /// build for `flavor`: the asset URL is `releases/download/<tag>/<filename>`. Returns nil
    /// when only the API can decide (no release.json, or the latest release lacks the flavor
    /// but an older one might have it).
    ///
    /// The result has no real release ID or date: `releaseID` is a negative hash of the tag
    /// and `publishedAt` is the stored date if an API call ever revealed it, else now.
    /// `InstalledAddon.isUpdate` compares tags for such releases.
    public func webResolve(_ ref: AddonRef, flavor: Flavor, background: Bool = false) async throws -> ResolvedRelease? {
        let (owner, repo) = try Self.split(ref)
        guard let tag = try await latestTag(for: ref, maxAge: 0, background: background) else { return nil }
        guard let json = try await webReleaseJSON(owner: owner, repo: repo, tag: tag, background: background),
              let build = json.release(for: flavor) else { return nil }
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

    /// A stable negative ID for a release known only by its tag (FNV-1a of `owner/repo@tag`).
    static func syntheticReleaseID(ref: AddonRef, tag: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(ref.identifier.lowercased())@\(tag)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return -Int64(hash & 0x3FFF_FFFF_FFFF_FFFF) - 1
    }

    // MARK: - Support checks

    public func support(for ref: AddonRef, flavor: Flavor) async -> SupportStatus {
        await check(ref, flavor: flavor).status
    }

    /// Decides support from the latest release's release.json on github.com, which costs
    /// no API quota:
    /// 1. `releases/latest` (redirect not followed) gives the tag, or says there are no releases.
    /// 2. If a stored verdict was made against the same tag, it's reused.
    /// 3. Otherwise `releases/download/<tag>/release.json` gives the flavors.
    ///
    /// Only the latest stable release is considered. Other failures give `.unknown`, which
    /// isn't retried for 15 minutes. If github.com fails while API quota is comfortable, the
    /// API path (`apiSupport`) answers instead.
    public func check(_ ref: AddonRef, flavor: Flavor, background: Bool = false) async -> SupportCheck {
        guard ref.source == .github, let (owner, repo) = try? Self.split(ref) else { return SupportCheck(status: .unknown) }
        let key = Self.cacheKey(ref) + "#" + flavor.rawValue
        if let hit = supportCache[key] {
            let ttl = hit.check.status == .unknown ? Self.errorTTL : Self.supportTTL
            if now().timeIntervalSince(hit.checkedAt) < ttl { return hit.check }
        }
        let result: SupportCheck
        do {
            if let tag = try await latestTag(for: ref, background: background) {
                if let stored = await storedVerdict(ref, flavor: flavor), stored.tag == tag {
                    result = SupportCheck(status: stored.status, tag: tag)
                } else if let json = try await webReleaseJSON(owner: owner, repo: repo, tag: tag, background: background) {
                    result = SupportCheck(status: json.release(for: flavor) != nil ? .supported(version: tag) : .unsupported, tag: tag)
                } else {
                    result = SupportCheck(status: .needsDownload, tag: tag)
                }
            } else {
                result = SupportCheck(status: .noReleases)
            }
        } catch AddonError.notFound {
            result = SupportCheck(status: .noReleases)
        } catch {
            // If github.com is pushing back, don't move the load onto the API quota.
            let pushedBack = (error as? AddonError).map(Self.isRateLimit) ?? false
            if !pushedBack, await quotaIsComfortable() {
                return SupportCheck(status: await apiSupport(for: ref, flavor: flavor))
            }
            result = SupportCheck(status: .unknown)
        }
        supportCache[key] = (result, now())
        return result
    }

    private static func isRateLimit(_ error: AddonError) -> Bool {
        if case .rateLimited = error { return true }
        return false
    }

    private func storedVerdict(_ ref: AddonRef, flavor: Flavor) async -> (status: SupportStatus, tag: String?)? {
        guard let row = try? await database?.query(
            "SELECT status, version, tag FROM support WHERE full_name = ? AND flavor = ? AND status != 'error'",
            ref.identifier, flavor.rawValue).first,
            let kind = row.string(0), let status = SupportCache.status(kind: kind, version: row.string(1)) else { return nil }
        return (status, row.string(2))
    }

    /// The older support check over the releases API. It looks past the latest release but
    /// costs one API call per repo, and returns `.unknown` within `supportReserve` of the limit.
    public func apiSupport(for ref: AddonRef, flavor: Flavor) async -> SupportStatus {
        guard ref.source == .github, let (owner, repo) = try? Self.split(ref) else { return .unknown }
        let key = Self.cacheKey(ref) + "#" + flavor.rawValue + "#api"
        let current = now()
        if let hit = supportCache[key], current.timeIntervalSince(hit.checkedAt) < Self.supportTTL {
            return hit.check.status
        }
        await loadRateLimitIfNeeded()
        if let remaining = rateRemaining, remaining <= Self.supportReserve, rateReset.map({ $0 > current }) ?? true {
            return .unknown
        }
        do {
            let releases = try await cachedReleases(ref, owner: owner, repo: repo)
            let status: SupportStatus
            if ReleaseSelector.eligible(releases, channel: .stable).isEmpty {
                status = .noReleases
            } else {
                switch try await select(ref: ref, releases: releases, flavor: flavor, channel: .stable, downloadZips: false) {
                case .selected(let release, _, _): status = .supported(version: release.tagName)
                case .needsDownload: status = .needsDownload
                case .none: status = .unsupported
                }
            }
            supportCache[key] = (SupportCheck(status: status), now())
            return status
        } catch {
            return .unknown
        }
    }

    // MARK: - Quota-free github.com routes

    /// Tag of the latest stable release (drafts and prereleases excluded), read from the
    /// `Location` of `github.com/<repo>/releases/latest` without following it (following
    /// would download the whole release page). Nil when the repo has no releases. Throws
    /// `notFound` for a missing repo. Costs no API quota. An answer younger than `maxAge`
    /// is reused; pass 0 to always ask.
    public func latestTag(
        for ref: AddonRef, maxAge: TimeInterval = GitHubSource.latestTagTTL, background: Bool = false
    ) async throws -> String? {
        let (owner, repo) = try Self.split(ref)
        let key = Self.cacheKey(ref)
        if let hit = latestTags[key], now().timeIntervalSince(hit.checkedAt) < maxAge {
            return hit.tag
        }
        let url = Self.webBase.appending(path: "\(owner)/\(repo)/releases/latest")
        let (_, response) = try await webRequest(url, method: "HEAD", followRedirects: false, background: background)
        let tag: String?
        switch response.statusCode {
        case 300..<400:
            let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: url) }
            tag = Self.tag(fromReleaseURL: location)
        case 200..<300:
            // A client that followed the redirect anyway: the final URL carries the tag.
            tag = Self.tag(fromReleaseURL: response.url)
        case 404:
            throw AddonError.notFound(ref)
        default:
            throw AddonError.http(status: response.statusCode, url: url)
        }
        latestTags[key] = (tag, now())
        return tag
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

    /// release.json of the release tagged `tag`, or nil if it has none.
    private func webReleaseJSON(owner: String, repo: String, tag: String, background: Bool) async throws -> ReleaseJSON? {
        let key = "\(owner)/\(repo)@\(tag)".lowercased()
        if let hit = tagReleaseJSON[key] { return hit }
        let url = Self.releaseDownloadURL(owner: owner, repo: repo, tag: tag, file: "release.json")
        let (data, response) = try await webRequest(url, method: "GET", background: background)
        let json: ReleaseJSON?
        switch response.statusCode {
        case 200..<300: json = try ReleaseJSON(data: data)
        case 404: json = nil
        default: throw AddonError.http(status: response.statusCode, url: url)
        }
        tagReleaseJSON[key] = .some(json)
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
