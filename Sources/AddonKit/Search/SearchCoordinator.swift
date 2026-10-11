import Foundation

/// Runs every search layer and merges them into one live result list (docs/design.md §7).
///
/// `search` emits local results (direct reference, installed, catalogue) at once,
/// then re-emits as Forever-support checks and GitHub live results land.
public actor SearchCoordinator {
    /// How many of the top visible results get a support check per search.
    public static let verificationLimit = 15
    /// Support checks in flight at once.
    public static let maxConcurrentChecks = 2
    /// Below this many catalogue matches, GitHub live search runs automatically.
    public static let liveSearchThreshold = 5
    /// Catalogue matches kept per search.
    public static let catalogueLimit = 200

    private let catalogue: CatalogueSource
    private let github: GitHubSearchProvider?
    private let support: any SupportChecking
    private let supportCache: SupportCache
    /// Star counts seen in GitHub results, keyed by lower-cased `owner/repo`.
    private var stars: [String: Int] = [:]

    public init(catalogue: CatalogueSource, github: GitHubSearchProvider?, support: any SupportChecking, supportCache: SupportCache) {
        self.catalogue = catalogue
        self.github = github
        self.support = support
        self.supportCache = supportCache
    }

    // MARK: Search

    /// Emits the merged result list, then again whenever a layer or support check lands.
    /// Finishes when all work is done; cancelling the consumer cancels outstanding work.
    public nonisolated func search(_ query: SearchQuery, installed: [AddonStatus]) -> AsyncStream<[SearchResult]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SearchResult].self)
        let task = Task {
            await self.run(query, installed: installed, continuation: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private enum Event: Sendable {
        case support(AddonRef, SupportStatus)
        case github([SearchResult])
        case githubFailed
    }

    private func run(_ query: SearchQuery, installed: [AddonStatus], continuation: AsyncStream<[SearchResult]>.Continuation) async {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            continuation.yield([])
            return
        }
        var session = Session(foreverOnly: query.foreverOnly)
        let cached = await supportCache.statuses(flavor: query.flavor)

        var installedByKey: [String: InstalledAddon] = [:]
        for status in installed {
            if case .managed(let addon, _) = status { installedByKey[Session.key(addon.id)] = addon }
        }

        // 1. Direct reference.
        let direct = Self.directReference(text)
        if let direct {
            session.merge(SearchResult(
                id: direct, name: String(direct.identifier.split(separator: "/").last ?? ""),
                owner: InstalledSearchProvider.owner(of: direct), origin: [.direct]
            ))
        }

        // 2. Installed.
        for result in InstalledSearchProvider(addons: installed).search(SearchQuery(text: text, flavor: query.flavor)) {
            session.merge(result)
        }

        // 3. Catalogue.
        let index = try? await catalogue.searchIndex()
        let catalogueMatches = index?.search(text, limit: Self.catalogueLimit) { cached[$0] } ?? []
        for entry in catalogueMatches {
            session.merge(result(for: entry, origin: .catalogue))
        }
        if let direct, let entry = index?.entry(for: direct) {
            session.merge(result(for: entry, origin: .catalogue))
        }

        session.attach(installed: installedByKey)
        session.apply(cached)
        guard !Task.isCancelled else { return }

        let runGitHub = github != nil
            && (query.includeLiveGitHub || (direct == nil && catalogueMatches.count < Self.liveSearchThreshold))
        session.queueVerification(limit: Self.verificationLimit)
        continuation.yield(session.visible)

        // 4. Support checks and GitHub live search.
        let support = self.support
        let github = self.github
        let flavor = query.flavor
        await withTaskGroup(of: Event.self) { group in
            if runGitHub, let github {
                group.addTask {
                    do { return .github(try await github.search(query)) } catch { return .githubFailed }
                }
            }
            var running = 0
            while running < Self.maxConcurrentChecks, let ref = session.nextToVerify() {
                running += 1
                group.addTask { .support(ref, await support.support(for: ref, flavor: flavor)) }
            }

            for await event in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                switch event {
                case .support(let ref, let status):
                    running -= 1
                    session.setSupport(status, for: ref)
                    await supportCache.set(status, for: ref, flavor: flavor)
                case .github(let results):
                    let live = results.map { result -> SearchResult in
                        var result = result
                        if let count = result.stars { stars[Session.key(result.id)] = count }
                        if let status = cached[result.id] { result.support = status }
                        return result
                    }
                    for result in live { session.merge(result) }
                    session.attach(installed: installedByKey)
                    session.queueVerification(limit: Self.verificationLimit)
                case .githubFailed:
                    continue
                }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                while running < Self.maxConcurrentChecks, let ref = session.nextToVerify() {
                    running += 1
                    group.addTask { .support(ref, await support.support(for: ref, flavor: flavor)) }
                }
                continuation.yield(session.visible)
            }
        }
    }

    private func result(for entry: CatalogueEntry, origin: SearchOrigin) -> SearchResult {
        SearchResult(
            id: entry.ref, name: entry.name, summary: entry.description, owner: entry.owner,
            stars: stars[Session.key(entry.ref)], lastUpdated: entry.lastUpdated, origin: [origin]
        )
    }

    // MARK: Browse

    /// The Browse tab's content for an empty search box (docs/design.md §7.5).
    public func browse(flavor: Flavor = .forever) async -> (popular: [SearchResult], recent: [SearchResult], categories: [SearchCategory]) {
        let statuses = await supportCache.statuses(flavor: flavor)
        let index = try? await catalogue.searchIndex()

        var popular: [SearchResult] = []
        for (ref, status) in statuses {
            guard case .supported = status else { continue }
            var result: SearchResult
            if let entry = index?.entry(for: ref) {
                result = self.result(for: entry, origin: .catalogue)
            } else {
                result = SearchResult(
                    id: ref, name: String(ref.identifier.split(separator: "/").last ?? ""),
                    owner: InstalledSearchProvider.owner(of: ref), stars: stars[Session.key(ref)], origin: []
                )
            }
            result.support = status
            popular.append(result)
        }
        popular.sort { a, b in
            if (a.stars ?? -1) != (b.stars ?? -1) { return (a.stars ?? -1) > (b.stars ?? -1) }
            if (a.lastUpdated ?? .distantPast) != (b.lastUpdated ?? .distantPast) {
                return (a.lastUpdated ?? .distantPast) > (b.lastUpdated ?? .distantPast)
            }
            return a.id.identifier.lowercased() < b.id.identifier.lowercased()
        }

        var recent: [SearchResult] = []
        for entry in index?.recentlyUpdated(limit: 60) ?? [] {
            var result = self.result(for: entry, origin: .catalogue)
            result.support = statuses[entry.ref] ?? .unknown
            if result.support.isVerifiedUnsupported { continue }
            recent.append(result)
            if recent.count == 20 { break }
        }

        return (Array(popular.prefix(20)), recent, SearchAliases.categories)
    }

    // MARK: Direct references

    /// `owner/repo`, `github.com/owner/repo` or a full GitHub URL → a GitHub ref.
    public static func directReference(_ text: String) -> AddonRef? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("github.com/") || lower.hasPrefix("www.github.com/") { s = "https://" + s }

        let owner: Substring, repo: Substring
        if s.contains("://") {
            guard let url = URL(string: s), let host = url.host()?.lowercased(),
                  host == "github.com" || host == "www.github.com" else { return nil }
            let parts = url.path().split(separator: "/")
            guard parts.count >= 2 else { return nil }
            owner = parts[0]
            repo = parts[1]
        } else {
            let parts = s.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            owner = parts[0]
            repo = parts[1]
        }
        var repoName = String(repo)
        if repoName.lowercased().hasSuffix(".git") { repoName.removeLast(4) }
        guard isValidOwner(owner), isValidRepo(repoName) else { return nil }
        return AddonRef(source: .github, identifier: "\(owner)/\(repoName)")
    }

    private static func isValidOwner(_ s: Substring) -> Bool {
        (1...39).contains(s.count) && s.first != "-"
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func isValidRepo(_ s: String) -> Bool {
        (1...100).contains(s.count) && s != "." && s != ".."
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}

// MARK: - Per-search state

private struct Session {
    var foreverOnly: Bool
    private(set) var results: [SearchResult] = []
    private var positions: [String: Int] = [:]
    private var queue: [AddonRef] = []
    /// Refs already queued or checked in this search.
    private var verified: Set<String> = []

    init(foreverOnly: Bool) {
        self.foreverOnly = foreverOnly
    }

    static func key(_ ref: AddonRef) -> String {
        "\(ref.source.rawValue):\(ref.identifier.lowercased())"
    }

    /// Adds a result, or folds it into an existing one with the same ref.
    mutating func merge(_ new: SearchResult) {
        let key = Self.key(new.id)
        guard let i = positions[key] else {
            positions[key] = results.count
            results.append(new)
            return
        }
        var existing = results[i]
        // A bare direct reference only knows the repo name; prefer the catalogue's.
        if existing.origin == [.direct] || existing.name.isEmpty { existing.name = new.name }
        existing.origin.formUnion(new.origin)
        existing.summary = existing.summary ?? new.summary
        existing.stars = existing.stars ?? new.stars
        existing.lastUpdated = existing.lastUpdated ?? new.lastUpdated
        existing.installed = existing.installed ?? new.installed
        if existing.support == .unknown { existing.support = new.support }
        results[i] = existing
    }

    mutating func attach(installed: [String: InstalledAddon]) {
        for i in results.indices where results[i].installed == nil {
            if let addon = installed[Self.key(results[i].id)] {
                results[i].installed = addon
                results[i].origin.insert(.installed)
            }
        }
    }

    mutating func apply(_ cached: [AddonRef: SupportStatus]) {
        for i in results.indices {
            if let status = cached[results[i].id] { results[i].support = status }
        }
    }

    /// Queues the top `limit` visible results that have no status yet, marking them `.checking`.
    mutating func queueVerification(limit: Int) {
        var considered = 0
        for i in results.indices where isVisible(results[i]) {
            considered += 1
            if considered > limit { break }
            let key = Self.key(results[i].id)
            guard results[i].support == .unknown, !verified.contains(key) else { continue }
            verified.insert(key)
            queue.append(results[i].id)
            results[i].support = .checking
        }
    }

    mutating func nextToVerify() -> AddonRef? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    mutating func setSupport(_ status: SupportStatus, for ref: AddonRef) {
        guard let i = positions[Self.key(ref)] else { return }
        results[i].support = status
    }

    private func isVisible(_ result: SearchResult) -> Bool {
        guard foreverOnly, result.support.isVerifiedUnsupported else { return true }
        // Installed add-ons and explicit references are always shown.
        return result.installed != nil || result.origin.contains(.installed) || result.origin.contains(.direct)
    }

    var visible: [SearchResult] {
        results.filter(isVisible)
    }
}
