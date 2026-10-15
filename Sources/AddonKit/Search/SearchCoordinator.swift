import Foundation

/// Runs every search layer and merges them into one result list (docs/features/search.md).
///
/// Search reads the local database; if it finds nothing, it asks GitHub once and remembers
/// the answer. It never checks support itself: results carry the stored verdict and the
/// flavors the latest release ships, or `.unknown` / nil until the add-on is opened,
/// installed, refreshed or scrolled into view in Browse (`AddonManager.checkVisible`).
public actor SearchCoordinator {
    /// Catalogue matches kept per search.
    /// Rows in each Browse list. The table is lazy, so this is about relevance, not cost.
    public static let browseLimit = 500
    public static let catalogueLimit = 200
    /// Below this many local results, GitHub live search runs automatically.
    public static let liveSearchThreshold = 3
    /// Shorter queries never trigger the automatic live search.
    public static let minimumLiveQueryLength = 3
    /// The automatic live search waits this long first, so only a settled query spends a request.
    public static let liveSearchDelay: Duration = .milliseconds(500)
    /// How long a live search answer is reused for the same query.
    public static let liveCacheTTL: TimeInterval = 24 * 60 * 60
    /// How long an empty live search answer is reused.
    public static let emptyLiveCacheTTL: TimeInterval = 60 * 60

    private let catalogue: CatalogueSource
    private let github: GitHubSearchProvider?
    private let supportCache: SupportCache
    private let now: @Sendable () -> Date
    var liveSearchDelay: Duration = SearchCoordinator.liveSearchDelay

    public init(
        catalogue: CatalogueSource, github: GitHubSearchProvider?, supportCache: SupportCache,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.catalogue = catalogue
        self.github = github
        self.supportCache = supportCache
        self.now = now
    }

    func setLiveSearchDelay(_ delay: Duration) {
        liveSearchDelay = delay
    }

    // MARK: Search

    /// Emits the local results, then once more if a live GitHub search adds any.
    /// Finishes when all work is done; cancelling the consumer cancels outstanding work.
    public nonisolated func search(_ query: SearchQuery, installed: [AddonStatus]) -> AsyncStream<[SearchResult]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SearchResult].self)
        let task = Task {
            var last: [SearchResult]?
            for await update in self.searchUpdates(query, installed: installed) where update.results != last {
                last = update.results
                continuation.yield(update.results)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Like `search`, but each emission also says whether a GitHub live search is running
    /// and whether this is the last one.
    public nonisolated func searchUpdates(_ query: SearchQuery, installed: [AddonStatus]) -> AsyncStream<SearchUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: SearchUpdate.self, bufferingPolicy: .bufferingNewest(8))
        let task = Task {
            await self.run(query, installed: installed, continuation: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(_ query: SearchQuery, installed: [AddonStatus], continuation: AsyncStream<SearchUpdate>.Continuation) async {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            continuation.yield(SearchUpdate(results: [], isComplete: true))
            return
        }
        var session = Session(flavor: query.flavor, hideIncompatible: query.hideIncompatible, games: query.games)
        // Sources that are off add no results; installed add-ons from them still show.
        let enabled = await supportCache.database.enabledSources()
        let statuses = await keyed(supportCache.statuses(flavor: query.flavor))
        let flavors = await supportCache.allAvailableFlavors()
        let stars = await supportCache.stars()
        let released = await supportCache.latestPublishedDates()

        var installedByKey: [String: InstalledAddon] = [:]
        for status in installed {
            if case .managed(let addon, _) = status { installedByKey[Session.key(addon.id)] = addon }
        }

        // 1. Direct reference.
        let direct = (Self.directReference(text) ?? HostedSources.parse(text)).flatMap { enabled.contains($0.source) ? $0 : nil }
        if let direct {
            session.merge(SearchResult(
                id: direct, name: Self.shortName(of: direct),
                owner: InstalledSearchProvider.owner(of: direct), origin: [.direct]
            ))
        }

        // 2. Installed.
        for result in InstalledSearchProvider(addons: installed).search(SearchQuery(text: text, flavor: query.flavor)) {
            session.merge(result)
        }

        // 3. Catalogue, from the database. Only a never-downloaded catalogue is fetched here.
        let index = await localIndex(githubEnabled: enabled.contains(.github))
        let matches = index?.search(text, limit: Self.catalogueLimit) { statuses[Session.key($0)] } ?? []
        for entry in matches {
            session.merge(Self.result(for: entry, origin: entry.fromLiveSearch ? .github : .catalogue, stars: stars))
        }
        if let direct, let entry = index?.entry(for: direct) {
            session.merge(Self.result(for: entry, origin: .catalogue, stars: stars))
        }

        session.attach(installed: installedByKey)
        session.apply(statuses, flavors: flavors, released: released)
        guard !Task.isCancelled else { return }

        // 4. GitHub live search, when asked or when the database can't answer.
        let explicit = query.includeLiveGitHub
        let automatic = direct == nil && session.count < Self.liveSearchThreshold && text.count >= Self.minimumLiveQueryLength
        guard let github, enabled.contains(.github), explicit || automatic else {
            continuation.yield(SearchUpdate(results: session.visible, isComplete: true))
            return
        }
        // A stored answer needs neither the settle delay nor the "searching GitHub" state.
        let live: [SearchResult]
        if let stored = await storedLiveResults(text, explicit: explicit, stars: stars) {
            live = stored
        } else {
            if !explicit {
                continuation.yield(SearchUpdate(results: session.visible))
                // Only a settled query spends a request: typing on cancels this search.
                try? await Task.sleep(for: liveSearchDelay)
                guard !Task.isCancelled else { return }
            }
            continuation.yield(SearchUpdate(results: session.visible, isSearchingGitHub: true))
            live = await liveResults(text, flavor: query.flavor, explicit: explicit, github: github, stars: stars)
        }
        guard !Task.isCancelled else { return }
        for result in live { session.merge(result) }
        session.attach(installed: installedByKey)
        session.apply(statuses, flavors: flavors, released: released)
        continuation.yield(SearchUpdate(results: session.visible, isComplete: true))
    }

    private func keyed(_ statuses: [AddonRef: SupportStatus]) -> [String: SupportStatus] {
        Dictionary(statuses.map { (Session.key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// The stored catalogue's index over the sources that are on. Downloads the GitHub
    /// catalogue only if it has never been fetched and GitHub is on.
    private func localIndex(githubEnabled: Bool) async -> SearchIndex? {
        if let index = try? await catalogue.localSearchIndex(), index.count > 0 { return index }
        guard githubEnabled, await catalogue.lastFetched() == nil else { return nil }
        return try? await catalogue.searchIndex()
    }

    /// `owner/repo` → `repo`; a hosted ref's identifier as is.
    static func shortName(of ref: AddonRef) -> String {
        String(ref.identifier.split(separator: "/").last ?? "")
    }

    private static func liveCacheKey(_ text: String, explicit: Bool) -> String {
        SearchText.fold(text.split(whereSeparator: \.isWhitespace).joined(separator: " ")) + (explicit ? "#all" : "")
    }

    /// The stored live answer for `text` while it's within its lifetime, else nil.
    private func storedLiveResults(_ text: String, explicit: Bool, stars: [String: Int]) async -> [SearchResult]? {
        let key = Self.liveCacheKey(text, explicit: explicit)
        guard let row = try? await supportCache.database.query("SELECT full_names, fetched_at FROM search_cache WHERE query = ?", key).first,
              let names = row.string(0), let fetched = row.date(1) else { return nil }
        let list = names.split(separator: "\n").map(String.init)
        let ttl = list.isEmpty ? Self.emptyLiveCacheTTL : Self.liveCacheTTL
        guard now().timeIntervalSince(fetched) < ttl else { return nil }
        var results: [SearchResult] = []
        for name in list {
            guard let entry = await catalogue.entry(for: AddonRef(source: .github, identifier: name)) else { continue }
            results.append(Self.result(for: entry, origin: .github, stars: stars))
        }
        return results
    }

    /// Live results for `text` from one request (three stages when `explicit`), stored for
    /// `storedLiveResults`. Failures and rate limits give no results, quietly.
    private func liveResults(
        _ text: String, flavor: Flavor, explicit: Bool, github: GitHubSearchProvider, stars: [String: Int]
    ) async -> [SearchResult] {
        let key = Self.liveCacheKey(text, explicit: explicit)
        let database = supportCache.database
        let found: [SearchResult]
        do {
            found = try await github.search(SearchQuery(text: text, flavor: flavor), stages: explicit ? nil : 1)
        } catch {
            return []
        }
        let entries = found.map { result in
            CatalogueEntry(
                id: result.id.identifier, name: result.name, fullName: result.id.identifier,
                url: URL(string: "https://github.com/\(result.id.identifier)")!, description: result.summary,
                lastUpdated: result.lastUpdated, fromLiveSearch: true
            )
        }
        try? await catalogue.remember(liveResults: entries)
        await supportCache.setStars(Dictionary(found.compactMap { r in r.stars.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a }))
        _ = try? await database.execute("""
            INSERT INTO search_cache(query, full_names, fetched_at) VALUES (?, ?, ?)
            ON CONFLICT(query) DO UPDATE SET full_names = excluded.full_names, fetched_at = excluded.fetched_at
            """, key, found.map(\.id.identifier).joined(separator: "\n"), now())
        return found
    }

    static func result(for entry: CatalogueEntry, origin: SearchOrigin, stars: [String: Int]) -> SearchResult {
        var result = SearchResult(
            id: entry.ref, name: entry.name, summary: entry.description, owner: entry.owner,
            stars: stars[entry.fullName.lowercased()], lastUpdated: entry.lastUpdated, origin: [origin]
        )
        // The catalogue knows which repos ship a release.json; without one, confirming
        // support needs a zip download, so there's nothing cheaper to check. Hosted add-ons
        // never have one, and show the games their listing claims until a zip says more.
        if !entry.fromLiveSearch, !entry.hasReleaseJSON { result.support = .needsDownload }
        result.availableFlavors = entry.listedFlavors
        return result
    }

    // MARK: Browse

    /// The Browse tab's content for an empty search box (docs/features/search.md). Local only.
    public func browse(flavor: Flavor) async -> (popular: [SearchResult], recent: [SearchResult], categories: [SearchCategory]) {
        let statuses = await supportCache.statuses(flavor: flavor)
        let keyedStatuses = keyed(statuses)
        let stars = await supportCache.stars()
        let flavors = await supportCache.allAvailableFlavors()
        let released = await supportCache.latestPublishedDates()
        let enabled = await supportCache.database.enabledSources()
        let index = await localIndex(githubEnabled: enabled.contains(.github))

        // Verdicts are GitHub's only, so Popular is empty with GitHub off.
        var popular: [SearchResult] = []
        for (ref, status) in statuses where enabled.contains(ref.source) {
            guard case .supported = status else { continue }
            var result: SearchResult
            if let entry = index?.entry(for: ref) {
                result = Self.result(for: entry, origin: .catalogue, stars: stars)
            } else {
                result = SearchResult(
                    id: ref, name: Self.shortName(of: ref),
                    owner: InstalledSearchProvider.owner(of: ref), stars: stars[ref.key.lowercased()], origin: []
                )
            }
            result.support = status
            result.availableFlavors = flavors[ref.key.lowercased()]
            result.lastUpdated = released[ref.key.lowercased()] ?? result.lastUpdated
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
        for entry in index?.recentlyUpdated(limit: Self.browseLimit * 2) ?? [] {
            var result = Self.result(for: entry, origin: .catalogue, stars: stars)
            if let status = keyedStatuses[Session.key(entry.ref)] { result.support = status }
            result.availableFlavors = flavors[entry.fullName.lowercased()] ?? result.availableFlavors
            result.lastUpdated = released[entry.fullName.lowercased()] ?? result.lastUpdated
            if flavor.hidesAsIncompatible(families: result.families, support: result.support) { continue }
            recent.append(result)
            if recent.count == Self.browseLimit { break }
        }

        return (Array(popular.prefix(Self.browseLimit)), recent, SearchAliases.categories)
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
    var flavor: Flavor
    var hideIncompatible: Bool
    var games: GameFamily?
    private(set) var results: [SearchResult] = []
    private var positions: [String: Int] = [:]

    init(flavor: Flavor, hideIncompatible: Bool, games: GameFamily? = nil) {
        self.flavor = flavor
        self.hideIncompatible = hideIncompatible
        self.games = games
    }

    var count: Int { results.count }

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
        // "Last updated" means the latest release: the installed copy's date is only a fallback.
        if existing.lastUpdated == nil || (existing.origin == [.installed] && new.lastUpdated != nil) {
            existing.lastUpdated = new.lastUpdated
        }
        existing.origin.formUnion(new.origin)
        existing.summary = existing.summary ?? new.summary
        existing.stars = existing.stars ?? new.stars
        existing.installed = existing.installed ?? new.installed
        if existing.support == .unknown { existing.support = new.support }
        existing.availableFlavors = existing.availableFlavors ?? new.availableFlavors
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

    /// Stored verdicts win over the catalogue's release.json hint, and the stored latest
    /// release date over the catalogue's. `flavors` and `released` are keyed by lower-cased
    /// `AddonRef.key`.
    mutating func apply(_ statuses: [String: SupportStatus], flavors: [String: Set<Flavor>], released: [String: Date] = [:]) {
        for i in results.indices {
            if let status = statuses[Self.key(results[i].id)] { results[i].support = status }
            if let available = flavors[results[i].id.key.lowercased()] { results[i].availableFlavors = available }
            if let date = released[results[i].id.key.lowercased()] { results[i].lastUpdated = date }
        }
    }

    private func isVisible(_ result: SearchResult) -> Bool {
        let incompatible = hideIncompatible && flavor.hidesAsIncompatible(families: result.families, support: result.support)
        let otherGame = games?.hides(families: result.families, support: result.support) ?? false
        guard incompatible || otherGame else { return true }
        // Installed add-ons and explicit references are always shown.
        return result.installed != nil || result.origin.contains(.installed) || result.origin.contains(.direct)
    }

    var visible: [SearchResult] {
        results.filter(isVisible)
    }
}
