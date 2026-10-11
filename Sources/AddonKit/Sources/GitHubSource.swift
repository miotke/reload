import Foundation

/// Resolves add-ons published as GitHub Releases (docs/design.md §6.5, §7.3).
///
/// - API calls go to `api.github.com` and count against the rate limit; release.json and zip
///   downloads use `browser_download_url`, which doesn't.
/// - The latest `x-ratelimit-remaining` / `x-ratelimit-reset` seen is exposed via `rateLimit()`.
public actor GitHubSource: Source, SupportChecking {
    public nonisolated let id: SourceID = .github

    /// `support(for:flavor:)` returns `.unknown` instead of calling the API when this few calls remain.
    public static let supportReserve = 10
    /// How long a `support(for:flavor:)` answer is reused without any request.
    public static let supportTTL: TimeInterval = 6 * 60 * 60
    /// Releases without release.json whose zips are downloaded before giving up.
    public static let maxInspectedReleases = 3

    static let apiBase = URL(string: "https://api.github.com")!

    private let http: HTTPClient
    private let token: String?
    private let cacheDirectory: URL?
    var now: @Sendable () -> Date = { Date() }

    private var rateRemaining: Int?
    private var rateReset: Date?
    /// Decoded release.json files by asset id. Assets are immutable, so these never expire.
    private var releaseJSONCache: [Int64: ReleaseJSON] = [:]
    /// Last 200 response of the releases endpoint per repo (lowercased `owner/repo`).
    private var releasesCache: [String: (etag: String, releases: [GitHubRelease])] = [:]
    private var supportCache: [String: (status: SupportStatus, checkedAt: Date)] = [:]

    public init(http: HTTPClient = URLSessionHTTPClient(), token: String? = nil, cacheDirectory: URL? = nil) {
        self.http = http
        self.token = token.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.cacheDirectory = cacheDirectory
    }

    /// Latest rate-limit state seen in any API response.
    public func rateLimit() -> (remaining: Int?, resetAt: Date?) {
        (rateRemaining, rateReset)
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) {
        now = clock
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

    // MARK: - Support checks

    public func support(for ref: AddonRef, flavor: Flavor) async -> SupportStatus {
        guard ref.source == .github, let (owner, repo) = try? Self.split(ref) else { return .unknown }
        let key = Self.cacheKey(ref) + "#" + flavor.rawValue
        let current = now()
        if let hit = supportCache[key], current.timeIntervalSince(hit.checkedAt) < Self.supportTTL {
            return hit.status
        }
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
            supportCache[key] = (status, now())
            return status
        } catch {
            return .unknown
        }
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
                for candidate in candidates {
                    let result: FlavorSupport
                    do {
                        result = try await inspect(candidate, flavor: flavor)
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

    private func fetchReleases(_ ref: AddonRef, owner: String, repo: String, etag: String?) async throws -> ReleasesResponse {
        let url = Self.releasesURL(owner: owner, repo: repo)
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // ETags are handled here; don't let URLSession's cache answer for us.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await http.data(for: request)
        trackRateLimit(response)
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
            if let newETag { releasesCache[Self.cacheKey(ref)] = (newETag, releases) }
            return .releases(releases, etag: newETag)
        case 404:
            throw AddonError.notFound(ref)
        default:
            throw apiError(response, url: url)
        }
    }

    private func apiError(_ response: HTTPURLResponse, url: URL) -> AddonError {
        let status = response.statusCode
        if status == 403 || status == 429 {
            let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            if remaining == 0 || retryAfter != nil {
                let reset = Self.resetDate(response) ?? retryAfter.map { now().addingTimeInterval($0) }
                rateRemaining = 0
                if let reset { rateReset = reset }
                return .rateLimited(resetAt: reset)
            }
        }
        return .http(status: status, url: url)
    }

    private func trackRateLimit(_ response: HTTPURLResponse) {
        if let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            rateRemaining = remaining
        }
        if let reset = Self.resetDate(response) {
            rateReset = reset
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

    private func inspect(_ asset: GitHubAsset, flavor: Flavor) async throws -> FlavorSupport {
        let safeName = asset.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let fileName = "\(asset.id)-\(safeName)"
        let fm = FileManager.default
        if let cacheDirectory {
            let file = cacheDirectory.appending(path: "downloads/github/\(fileName)", directoryHint: .notDirectory)
            if !fm.fileExists(atPath: file.path(percentEncoded: false)) {
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
        let file = dir.appending(path: fileName, directoryHint: .notDirectory)
        try data.write(to: file)
        return try ZipInspector.inspect(zipAt: file, flavor: flavor)
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
