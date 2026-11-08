import Foundation

/// Resolves add-ons published as GitHub Releases over the releases API
/// (docs/features/release-selection.md): parses refs, drives `ReleaseSelector` over the
/// releases list, and inspects zips when a release has no release.json.
///
/// Every request here goes to `api.github.com` (through `api`) and counts against the rate
/// limit, apart from release.json and zip downloads. Support verdicts and latest tags aren't
/// decided here: that's `LatestReleaseStore`, which falls back to `apiSupport`.
public actor GitHubReleaseResolver: Source {
    public nonisolated let id: SourceID = .github

    /// Releases without release.json whose zips are downloaded before giving up.
    public static let maxInspectedReleases = 3
    /// Zips inspected per release without release.json.
    public static let maxCandidatesPerRelease = 2
    /// Zips larger than this are never downloaded just to be inspected.
    public static let maxInspectedBytes = 200 * 1024 * 1024

    public nonisolated let api: GitHubAPIClient
    private let web: GitHubWebClient
    private let cacheDirectory: URL?
    /// Where inspected zips are kept: the `Downloader`'s archive path, so an install reuses them.
    private let archiveURL: (@Sendable (ResolvedRelease) -> URL)?

    /// Decoded release.json files by asset id. Assets are immutable, so these never expire.
    private var releaseJSONCache: [Int64: ReleaseJSON] = [:]

    /// A source with its own API and web clients, for parsing and resolving on their own.
    public init(http: HTTPClient = URLSessionHTTPClient(), token: String? = nil, cacheDirectory: URL? = nil) {
        self.init(api: GitHubAPIClient(http: http, token: token), web: GitHubWebClient(http: http), cacheDirectory: cacheDirectory)
    }

    /// - Parameter archiveURL: where to keep inspected zips (`Downloader.archiveURL(for:)`).
    public init(
        api: GitHubAPIClient, web: GitHubWebClient, cacheDirectory: URL? = nil,
        archiveURL: (@Sendable (ResolvedRelease) -> URL)? = nil
    ) {
        self.api = api
        self.web = web
        self.cacheDirectory = cacheDirectory
        self.archiveURL = archiveURL
    }

    // MARK: - Parsing

    /// Accepts `owner/repo`, `github:owner/repo` and `github.com` URLs (with `.git`, a trailing
    /// slash, or `/releases…`, `/tags`, `/tree/…`, `/blob/…` after the repo). `owner/repo#prefix`
    /// and `github:owner/repo#prefix` name one tag stream of the repo (`AddonRef.tagPrefix`);
    /// a URL's `#fragment` is a page anchor and is ignored.
    public nonisolated func parse(_ input: String) -> AddonRef? {
        Self.parseRef(input)
    }

    static func parseRef(_ input: String) -> AddonRef? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lowered = text.lowercased()
        var prefix: String?
        if !text.contains("://"), !lowered.hasPrefix("github.com/"), !lowered.hasPrefix("www.github.com/"),
           let hash = text.firstIndex(of: "#") {
            let value = String(text[text.index(after: hash)...])
            guard isValidPrefix(value) else { return nil }
            prefix = value
            text = String(text[..<hash])
        }
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
        return AddonRef(source: .github, identifier: "\(owner)/\(repo)", tagPrefix: prefix)
    }

    /// A tag prefix: what comes before a tag's first `/`, so never a `/` or `#`.
    static func isValidPrefix(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil
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
        let cached = await api.cachedReleases(for: ref)
        var releases: [GitHubRelease]
        let responseETag: String?
        switch try await api.fetchReleases(ref, owner: owner, repo: repo, etag: etag ?? cached?.etag) {
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
        // Callers resolve a stream over the stored listing (`resolve(_:within:…)`); this only
        // makes sure a prefixed ref never lands on another stream's release.
        if let prefix = ref.tagPrefix { releases = ReleaseStreams.releases(releases, inStream: prefix) }

        switch try await select(ref: ref, releases: releases, flavor: flavor, channel: channel, downloadZips: true) {
        case .selected(let release, let asset, let reasoning):
            return .release(resolved(ref, repo: repo, release: release, asset: asset, flavor: flavor, reasoning: reasoning), etag: responseETag)
        case .needsDownload, .none:
            throw AddonError.noCompatibleRelease(ref, flavor)
        }
    }

    /// Resolves within one tag stream, over releases `LatestReleaseStore.listing` stored, so
    /// no API request (docs/features/optional-parts.md#resolving-a-stream). A release with a
    /// release.json is chosen as usual. Without one, a zip is taken without being downloaded
    /// when the stream leaves no doubt: the successor of the installed zip (same name but for
    /// the version), or the release's only zip. Voice packs are 0.4–1.6 GB, so a check
    /// mustn't fetch one to look inside. Other zips are inspected only with `downloadZips`.
    func resolve(
        _ ref: AddonRef, within releases: [GitHubRelease], prefix: String, flavor: Flavor, channel: Channel,
        installed: (assetName: String, tag: String)?, downloadZips: Bool
    ) async throws -> ResolvedRelease {
        let (_, repo) = try Self.split(ref)
        let stream = ReleaseStreams.releases(releases, inStream: prefix)
        let installedStem = installed.map { ReleaseStreams.stem(of: $0.assetName, tag: $0.tag) }
        let trust: Trust = { release, candidates in
            if let installedStem, let next = candidates.first(where: { ReleaseStreams.stem(of: $0.name, tag: release.tagName) == installedStem }) {
                return (next, "same zip as installed (\(installed?.assetName ?? "")); not downloaded to inspect")
            }
            if candidates.count == 1 { return (candidates[0], "the stream's only zip; not downloaded to inspect") }
            return nil
        }
        switch try await select(ref: ref, releases: stream, flavor: flavor, channel: channel, downloadZips: downloadZips, trust: trust) {
        case .selected(let release, let asset, let reasoning):
            return resolved(ref, repo: repo, release: release, asset: asset, flavor: flavor, reasoning: ["stream \(prefix)/…"] + reasoning)
        case .needsDownload, .none:
            throw AddonError.noCompatibleRelease(ref, flavor)
        }
    }

    private func resolved(
        _ ref: AddonRef, repo: String, release: GitHubRelease, asset: GitHubAsset, flavor: Flavor, reasoning: [String]
    ) -> ResolvedRelease {
        let entryName = release.releaseJSONAsset
            .flatMap { releaseJSONCache[$0.id] }?
            .release(for: flavor)?.name
        return ResolvedRelease(
            ref: ref,
            // A part is named for its zip (`SpokenPlacesAudio`); the whole repo keeps its name.
            name: entryName ?? (ref.tagPrefix != nil ? Self.displayName(of: asset.name, tag: release.tagName) : repo),
            version: release.tagName,
            releaseID: release.id,
            publishedAt: release.publishedAt ?? release.createdAt ?? .distantPast,
            downloadURL: asset.browserDownloadURL,
            assetName: asset.name,
            changelog: release.body,
            isPrerelease: release.prerelease,
            reasoning: reasoning
        )
    }

    /// `SpokenPlacesAudio` for `SpokenPlacesAudio-2.1.0.zip` of `places-audio/v2.1.0`.
    static func displayName(of assetName: String, tag: String) -> String {
        var name = assetName
        if name.lowercased().hasSuffix(".zip") { name.removeLast(4) }
        let version = ReleaseStreams.version(ofTag: tag)
        if !version.isEmpty { name = name.replacingOccurrences(of: version, with: "") }
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        return trimmed.isEmpty ? assetName : trimmed
    }

    /// The older support check over the releases API. It looks past the latest release but
    /// costs one API call per repo, and returns `.unknown` within `supportReserve` of the limit.
    /// Used by `LatestReleaseStore.check` only when a foreground github.com check fails, quota is comfortable
    /// and the repo's API check is due.
    public func apiSupport(for ref: AddonRef, flavor: Flavor) async -> SupportStatus {
        guard ref.source == .github, let (owner, repo) = try? Self.split(ref) else { return .unknown }
        if await api.isWithinSupportReserve() { return .unknown }
        do {
            let releases = try await api.revalidatedReleases(ref, owner: owner, repo: repo)
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

    // MARK: - Selection loop

    enum Outcome {
        case selected(GitHubRelease, GitHubAsset, reasoning: [String])
        /// Only zip inspection could decide, and downloads weren't allowed.
        case needsDownload
        case none(reasoning: [String])
    }

    /// Picks a zip of a release without release.json without inspecting it, with the reason,
    /// or nil to inspect as usual.
    typealias Trust = @Sendable (GitHubRelease, [GitHubAsset]) -> (GitHubAsset, String)?

    /// Drives `ReleaseSelector`: fetches release.json files it asks for and, when `downloadZips`,
    /// downloads and inspects candidate zips for up to `maxInspectedReleases` releases.
    /// `trust` can take a zip without inspection first. Zips over `maxInspectedBytes` are
    /// never downloaded to be inspected: inspection holds the whole zip in memory.
    func select(
        ref: AddonRef, releases: [GitHubRelease], flavor: Flavor, channel: Channel, downloadZips: Bool, trust: Trust? = nil
    ) async throws -> Outcome {
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
                if let (asset, why) = trust?(release, candidates) {
                    return .selected(release, asset, reasoning: annotate(reasoning) + ["\(asset.name): \(why)"])
                }
                guard downloadZips else { return .needsDownload }
                guard inspected < Self.maxInspectedReleases else {
                    return .none(reasoning: annotate(reasoning) + ["stopped after inspecting \(Self.maxInspectedReleases) releases without release.json"])
                }
                inspected += 1
                for candidate in candidates.prefix(Self.maxCandidatesPerRelease) {
                    guard candidate.size <= Self.maxInspectedBytes else {
                        notes[release.id, default: []].append("\(candidate.name): too large to inspect (\(ByteCountFormatter.string(fromByteCount: Int64(candidate.size), countStyle: .file)))")
                        continue
                    }
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

    // MARK: - release.json

    private func releaseJSON(for asset: GitHubAsset) async throws -> ReleaseJSON {
        if let hit = releaseJSONCache[asset.id] { return hit }
        let file = cacheDirectory?.appending(path: "github/release-json/\(asset.id).json", directoryHint: .notDirectory)
        if let file, let data = try? Data(contentsOf: file), let json = try? ReleaseJSON(data: data) {
            return json
        }
        let data = try await web.download(asset.browserDownloadURL)
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
                let data = try await web.download(asset.browserDownloadURL)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }
            return try ZipInspector.inspect(zipAt: file, flavor: flavor)
        }
        let data = try await web.download(asset.browserDownloadURL)
        let dir = fm.temporaryDirectory.appending(path: "Reload-inspect-\(UUID().uuidString)", directoryHint: .isDirectory)
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
