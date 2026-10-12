import Foundation

/// The GitHub REST API (`api.github.com`), the only GitHub host that costs quota
/// (docs/network/github-endpoints.md).
///
/// - Owns the token, read lazily so creating a client never waits on the Keychain.
/// - Owns the `core` rate-limit state. With a database it's shared with other processes,
///   and no request is made while it says the quota is used up.
/// - Keeps the last releases list per repo in memory, revalidated with its ETag.
public actor GitHubAPIClient {
    /// `GitHubReleaseResolver.apiSupport` returns `.unknown` instead of calling the API when this few calls remain.
    public static let supportReserve = 10
    /// Optional API calls (README fallback, release details) are only made above this many.
    public static let comfortableQuota = 30
    /// Repos whose last releases response is kept in memory for ETag revalidation.
    static let releasesCacheLimit = 64

    static let base = URL(string: "https://api.github.com")!

    private let http: HTTPClient
    private var token: String?
    /// Resolves the token on first API use, so creating a client never waits on the Keychain.
    private var tokenProvider: (@Sendable () -> String?)?
    private let database: MetadataDatabase?
    /// Where each releases request is recorded, for the 6-hour API throttle
    /// (`LatestReleaseStore.apiCheckIsDue`).
    private let store: SupportCache?
    var now: @Sendable () -> Date = { Date() }

    private var rateRemaining: Int?
    private var rateReset: Date?
    private var loadedRateLimit = false
    /// Last 200 response of the releases endpoint per repo (lowercased `owner/repo`), capped
    /// at `releasesCacheLimit` with the least recently stored dropped first.
    private var releasesCache: [String: (etag: String, releases: [GitHubRelease])] = [:]
    private var releasesCacheOrder: [String] = []

    /// - Parameters:
    ///   - database: shares the rate-limit state with other processes.
    ///   - store: records when each repo's releases were last asked for.
    ///   - tokenProvider: read once, on the first API call, when `token` is nil.
    public init(
        http: HTTPClient = URLSessionHTTPClient(), token: String? = nil, database: MetadataDatabase? = nil,
        store: SupportCache? = nil, tokenProvider: (@Sendable () -> String?)? = nil
    ) {
        self.http = http
        self.token = Self.clean(token)
        self.tokenProvider = token == nil ? tokenProvider : nil
        self.database = database
        self.store = store
    }

    private static func clean(_ token: String?) -> String? {
        token.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    // MARK: - Token and quota

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

    func setClock(_ clock: @escaping @Sendable () -> Date) {
        now = clock
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

    /// True when optional API calls won't eat into what installs and updates need.
    /// Unknown counts as comfortable: nothing has been spent yet.
    public func quotaIsComfortable() async -> Bool {
        await loadRateLimitIfNeeded()
        guard let rateRemaining else { return true }
        if let rateReset, rateReset <= now() { return true }
        return rateRemaining > Self.comfortableQuota
    }

    /// True within `supportReserve` calls of the limit, until it resets: the calls left are
    /// kept for installs and updates.
    func isWithinSupportReserve() async -> Bool {
        let date = now()
        await loadRateLimitIfNeeded()
        guard let remaining = rateRemaining, remaining <= Self.supportReserve else { return false }
        return rateReset.map { $0 > date } ?? true
    }

    /// Throws `rateLimited` instead of spending a request the quota doesn't have.
    /// (A 304 still counts against the quota when unauthenticated.)
    private func checkQuota() async throws {
        await loadRateLimitIfNeeded()
        if rateRemaining == 0, let rateReset, rateReset > now() {
            throw AddonError.rateLimited(resetAt: rateReset)
        }
    }

    // MARK: - Requests

    /// GET from the API with the usual headers; used for release notes and the README fallback.
    func get(_ url: URL, accept: String = "application/vnd.github+json") async throws -> (Data, HTTPURLResponse) {
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

    enum ReleasesResponse {
        case notModified
        case releases([GitHubRelease], etag: String?)
    }

    static func releasesURL(owner: String, repo: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/repos/\(owner)/\(repo)/releases"
        components.queryItems = [URLQueryItem(name: "per_page", value: "10")]
        return components.url!
    }

    /// The releases list this process last received for `ref`, with its ETag.
    func cachedReleases(for ref: AddonRef) -> (etag: String, releases: [GitHubRelease])? {
        releasesCache[GitHubReleaseResolver.cacheKey(ref)]
    }

    /// The last 10 releases of `ref`. A 200 with an ETag is kept in memory.
    func fetchReleases(_ ref: AddonRef, owner: String, repo: String, etag: String?) async throws -> ReleasesResponse {
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
            await store?.setAPIChecked(at: now(), for: ref)
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
            if let newETag { remember(releases, etag: newETag, key: GitHubReleaseResolver.cacheKey(ref)) }
            return .releases(releases, etag: newETag)
        case 404:
            throw AddonError.notFound(ref)
        default:
            throw await apiError(response, data: data, url: url)
        }
    }

    /// Releases for `ref`, revalidating the in-memory copy with its ETag.
    func revalidatedReleases(_ ref: AddonRef, owner: String, repo: String) async throws -> [GitHubRelease] {
        let cached = cachedReleases(for: ref)
        switch try await fetchReleases(ref, owner: owner, repo: repo, etag: cached?.etag) {
        case .notModified:
            guard let cached else { throw AddonError.http(status: 304, url: Self.releasesURL(owner: owner, repo: repo)) }
            return cached.releases
        case .releases(let list, _):
            return list
        }
    }

    /// Notes of the latest stable release: at most one API call (`releases/latest`), none
    /// if the releases list this process already holds has that tag. Never downloads zips.
    /// Nil when the repo has no releases.
    public func releaseNotes(for ref: AddonRef, tag: String?) async throws -> (version: String, publishedAt: Date?, markdown: String)? {
        let (owner, repo) = try GitHubReleaseResolver.split(ref)
        if let tag, let cached = cachedReleases(for: ref)?.releases.first(where: { $0.tagName == tag }) {
            return (cached.tagName, cached.publishedAt ?? cached.createdAt, cached.body ?? "")
        }
        let url = Self.base.appending(path: "repos/\(owner)/\(repo)/releases/latest")
        let (data, response) = try await get(url)
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

    private func remember(_ releases: [GitHubRelease], etag: String, key: String) {
        if releasesCache[key] == nil { releasesCacheOrder.append(key) }
        releasesCache[key] = (etag, releases)
        while releasesCacheOrder.count > Self.releasesCacheLimit {
            releasesCache[releasesCacheOrder.removeFirst()] = nil
        }
    }

    // MARK: - Rate limit

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
}
