import Foundation

/// Which catalogue rows a fetch inserted or changed (docs/features/search.md).
public struct CatalogueDiff: Sendable, Hashable {
    /// `owner/repo` of rows that are new or whose data changed.
    public var changed: Set<String> = []
    /// `owner/repo` of rows that left the catalogue.
    public var removed: Set<String> = []
    /// False when nothing was downloaded (fresh, 304, or backing off after a failure).
    public var fetched = false

    public init(changed: Set<String> = [], removed: Set<String> = [], fetched: Bool = false) {
        self.changed = changed
        self.removed = removed
        self.fetched = fetched
    }
}

/// `github-wow-addon-catalogue/addons.csv`, kept in the metadata database (docs/features/search.md).
///
/// - Rows live in the `catalogue` table, upserted once per download in one transaction.
///   Unchanged rows aren't rewritten, so the diff says which repos changed.
/// - The copy is trusted for 24 h, then revalidated with `If-None-Match`.
/// - A stale copy is served at once while it revalidates in the background. After a failed
///   download, no new attempt is made for 15 minutes (the failure time is stored, so the
///   CLI and app share it).
public actor CatalogueSource {
    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/layday/github-wow-addon-catalogue/main/addons.csv")!
    /// The binary-plist cache earlier versions wrote to the caches folder. No longer used.
    public static let cacheFileName = "catalogue.plist"
    public static let maxAge: TimeInterval = 24 * 60 * 60
    /// How long to wait after a failed download before trying again.
    public static let failureBackoff: TimeInterval = 15 * 60

    private let http: any HTTPClient
    private let database: MetadataDatabase
    private let url: URL
    private let now: @Sendable () -> Date
    /// Rows as last read from the database; nil until loaded or after a write.
    private var cached: [CatalogueEntry]? {
        didSet { if cached == nil { generation += 1 } }
    }
    private var generation = 0
    private var index: (generation: Int, sources: Set<SourceID>, value: SearchIndex)?
    private var inFlight: Task<CatalogueDiff, any Error>?

    public init(
        http: any HTTPClient,
        database: MetadataDatabase,
        url: URL = CatalogueSource.defaultURL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.database = database
        self.url = url
        self.now = now
    }

    /// Opens (or creates) the metadata database in `cacheDirectory`. Prefer `init(http:database:)`
    /// with the shared database; this exists for callers that only have a folder.
    public init(
        http: any HTTPClient,
        cacheDirectory: URL,
        url: URL = CatalogueSource.defaultURL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let database = (try? MetadataDatabase(url: cacheDirectory.appending(path: MetadataDatabase.fileName)))
            ?? (try! MetadataDatabase.inMemory())
        self.init(http: http, database: database, url: url, now: now)
    }

    // MARK: - Reading

    /// Catalogue entries. Downloads only when nothing is stored yet; a stale copy is
    /// returned immediately and revalidated in the background.
    public func entries() async throws -> [CatalogueEntry] {
        let stored = try await localEntries()
        if stored.isEmpty {
            let state = try await database.catalogueState()
            if let failed = state.failedAt, now().timeIntervalSince(failed) < Self.failureBackoff {
                throw lastError ?? URLError(.cannotConnectToHost)
            }
            _ = try await fetch(force: true)
            return try await localEntries()
        }
        if try await needsRevalidation(), inFlight == nil {
            inFlight = Task { defer { self.inFlight = nil }; return try await self.download() }
        }
        return stored
    }

    /// What's stored, without touching the network.
    public func localEntries() async throws -> [CatalogueEntry] {
        if let cached { return cached }
        let entries = try await database.catalogueEntries()
        cached = entries
        return entries
    }

    /// A search index over `entries()` from the sources turned on in Settings, rebuilt only
    /// when the rows or the sources change.
    public func searchIndex() async throws -> SearchIndex {
        let entries = try await entries()
        return index(for: entries, sources: await database.enabledSources())
    }

    /// A search index over what's stored, without touching the network.
    public func localSearchIndex() async throws -> SearchIndex {
        index(for: try await localEntries(), sources: await database.enabledSources())
    }

    /// Forgets the rows read so far, after a hosted listing was imported.
    func invalidate() {
        cached = nil
    }

    /// Lookups by CurseForge, Wago and WoWInterface ID and by name over what's stored, for
    /// adoption suggestions. Local only; rebuilt only when the rows change.
    public func adoptionIndex() async -> AdoptionIndex {
        let entries = (try? await localEntries()) ?? []
        if let adoption, adoption.generation == generation { return adoption.value }
        // Suggestions are GitHub repos only; hosted rows would match by name too loosely.
        let built = AdoptionIndex(entries: entries.filter { $0.source == .github })
        adoption = (generation, built)
        return built
    }

    private var adoption: (generation: Int, value: AdoptionIndex)?

    private func index(for entries: [CatalogueEntry], sources: Set<SourceID>) -> SearchIndex {
        if let index, index.generation == generation, index.sources == sources { return index.value }
        let built = SearchIndex(entries: entries.filter { sources.contains($0.source) })
        index = (generation, sources, built)
        return built
    }

    /// The stored row for `ref`, without touching the network.
    public func entry(for ref: AddonRef) async -> CatalogueEntry? {
        try? await database.catalogueEntry(fullName: ref.key)
    }

    /// When the stored copy was last confirmed with the server, if ever.
    public func lastFetched() async -> Date? {
        try? await database.catalogueState().fetchedAt
    }

    // MARK: - Fetching

    /// Downloads the catalogue if the stored copy is older than 24 h (or always with
    /// `force`), and reports which repos changed. Respects the failure backoff unless forced.
    @discardableResult
    public func refresh(force: Bool = false) async throws -> CatalogueDiff {
        try await fetch(force: force)
    }

    /// Waits for a background revalidation started by `entries()`, if any.
    func waitForRevalidation() async {
        _ = try? await inFlight?.value
    }

    private func fetch(force: Bool) async throws -> CatalogueDiff {
        if let inFlight { return try await inFlight.value }
        if !force, !(try await needsRevalidation()) { return CatalogueDiff() }
        let task = Task { try await self.download() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func needsRevalidation() async throws -> Bool {
        let state = try await database.catalogueState()
        let current = now()
        if let failed = state.failedAt, current.timeIntervalSince(failed) < Self.failureBackoff { return false }
        guard let fetched = state.fetchedAt else { return true }
        return current.timeIntervalSince(fetched) >= Self.maxAge
    }

    private var lastError: (any Error)?

    private func download() async throws -> CatalogueDiff {
        let state = try await database.catalogueState()
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let hasRows = !(try await localEntries()).isEmpty
        if hasRows, let etag = state.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await http.data(for: request)
            switch response.statusCode {
            case 304:
                try await database.setCatalogueState(etag: state.etag, fetchedAt: now(), failedAt: nil)
                return CatalogueDiff()
            case 200:
                let entries = CatalogueCSV.entries(from: data)
                guard !entries.isEmpty else { throw AddonError.http(status: 200, url: url) }
                let diff = try await database.importCatalogue(entries, etag: response.value(forHTTPHeaderField: "ETag"), at: now())
                cached = nil
                return diff
            default:
                throw AddonError.http(status: response.statusCode, url: url)
            }
        } catch {
            lastError = error
            try? await database.setCatalogueState(etag: state.etag, fetchedAt: state.fetchedAt, failedAt: now())
            throw error
        }
    }

    // MARK: - Live search results

    /// Stores repos found by a live GitHub search so the next search finds them locally.
    /// Never overwrites a row the catalogue itself provided.
    public func remember(liveResults entries: [CatalogueEntry]) async throws {
        guard !entries.isEmpty else { return }
        try await database.rememberLiveResults(entries, at: now())
        cached = nil
    }
}

// MARK: - Database access

struct CatalogueState: Sendable {
    var etag: String?
    var fetchedAt: Date?
    var failedAt: Date?
}

extension MetadataDatabase {
    static let catalogueColumns = """
        full_name, id, name, description, url, last_updated, flavors, curse_id, wago_id, wowi_id, has_release_json, source
        """
    /// `catalogueColumns` plus the columns only hosted rows fill.
    static let catalogueReadColumns = catalogueColumns + ", author, screenshots_json"

    func catalogueState() throws -> CatalogueState {
        guard let row = try query("SELECT etag, fetched_at, failed_at FROM catalogue_state WHERE id = 1").first else {
            return CatalogueState()
        }
        return CatalogueState(etag: row.string(0), fetchedAt: row.date(1), failedAt: row.date(2))
    }

    func setCatalogueState(etag: String?, fetchedAt: Date?, failedAt: Date?) throws {
        try execute("""
            INSERT INTO catalogue_state(id, etag, fetched_at, failed_at) VALUES (1, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET etag = excluded.etag, fetched_at = excluded.fetched_at, failed_at = excluded.failed_at
            """, etag, fetchedAt, failedAt)
    }

    func catalogueEntries() throws -> [CatalogueEntry] {
        try query("SELECT \(Self.catalogueReadColumns) FROM catalogue ORDER BY full_name").compactMap(Self.entry)
    }

    func catalogueEntry(fullName: String) throws -> CatalogueEntry? {
        try query("SELECT \(Self.catalogueReadColumns) FROM catalogue WHERE full_name = ?", fullName).first.flatMap(Self.entry)
    }

    static func entry(_ row: SQLRow) -> CatalogueEntry? {
        guard let fullName = row.string(0), let id = row.string(1), let name = row.string(2),
              let url = row.string(4).flatMap(URL.init(string:)) else { return nil }
        // `source` is `catalogue` or `github_search` for GitHub rows, else the host.
        let source = row.string(11).flatMap(SourceID.init(rawValue:)) ?? .github
        let screenshots = (row.string(13).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
            .compactMap(URL.init(string:))
        return CatalogueEntry(
            id: id, name: name, fullName: fullName, url: url, description: row.string(3),
            lastUpdated: row.date(5),
            flavors: (row.string(6) ?? "").split(separator: ",").map(String.init),
            curseID: row.int(7), wagoID: row.string(8), wowiID: row.int(9),
            hasReleaseJSON: row.bool(10), fromLiveSearch: row.string(11) == "github_search",
            source: source, author: row.string(12), screenshots: screenshots
        )
    }

    /// Upserts every catalogue row in one transaction, skipping rows whose data is
    /// unchanged, and deletes catalogue rows the file no longer lists.
    func importCatalogue(_ entries: [CatalogueEntry], etag: String?, at date: Date) throws -> CatalogueDiff {
        let diff = try transaction { db in
            var diff = CatalogueDiff(fetched: true)
            var listed = Set<String>()
            let upsert = try db.prepare("""
                    INSERT INTO catalogue(\(Self.catalogueColumns), first_seen_at, seen_at, changed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'catalogue', ?, ?, ?)
                    ON CONFLICT(full_name) DO UPDATE SET
                        id = excluded.id, name = excluded.name, description = excluded.description, url = excluded.url,
                        last_updated = excluded.last_updated, flavors = excluded.flavors, curse_id = excluded.curse_id,
                        wago_id = excluded.wago_id, wowi_id = excluded.wowi_id, has_release_json = excluded.has_release_json,
                        source = 'catalogue', seen_at = excluded.seen_at, changed_at = excluded.changed_at
                    WHERE (catalogue.id, catalogue.name, catalogue.description, catalogue.url, catalogue.last_updated,
                           catalogue.flavors, catalogue.curse_id, catalogue.wago_id, catalogue.wowi_id,
                           catalogue.has_release_json, catalogue.source)
                       IS NOT (excluded.id, excluded.name, excluded.description, excluded.url, excluded.last_updated,
                               excluded.flavors, excluded.curse_id, excluded.wago_id, excluded.wowi_id,
                               excluded.has_release_json, 'catalogue')
                    """)
            let seen = date.sqlValue
            for entry in entries {
                listed.insert(entry.fullName.lowercased())
                let changes = try db.step(upsert, [
                    .text(entry.fullName), .text(entry.id), .text(entry.name), entry.description.sqlValue,
                    .text(entry.url.absoluteString), entry.lastUpdated.sqlValue, .text(entry.flavors.joined(separator: ",")),
                    entry.curseID.sqlValue, entry.wagoID.sqlValue, entry.wowiID.sqlValue, entry.hasReleaseJSON.sqlValue,
                    seen, seen, seen,
                ])
                if changes > 0 { diff.changed.insert(entry.fullName) }
            }
            for row in try db.query("SELECT full_name FROM catalogue WHERE source = 'catalogue'") {
                guard let name = row.string(0), !listed.contains(name.lowercased()) else { continue }
                try db.execute("DELETE FROM catalogue WHERE full_name = ?", name)
                diff.removed.insert(name)
            }
            try db.setCatalogueState(etag: etag, fetchedAt: date, failedAt: nil)
            return diff
        }
        notify(["catalogue"], repos: diff.changed.union(diff.removed))
        return diff
    }

    func rememberLiveResults(_ entries: [CatalogueEntry], at date: Date) throws {
        try transaction { db in
            for entry in entries {
                try db.execute("""
                    INSERT INTO catalogue(\(Self.catalogueColumns), first_seen_at, seen_at, changed_at)
                    VALUES (?, ?, ?, ?, ?, ?, '', NULL, NULL, NULL, 0, 'github_search', ?, ?, ?)
                    ON CONFLICT(full_name) DO UPDATE SET
                        description = excluded.description, last_updated = excluded.last_updated, seen_at = excluded.seen_at
                    WHERE catalogue.source = 'github_search'
                        AND (catalogue.description, catalogue.last_updated) IS NOT (excluded.description, excluded.last_updated)
                    """,
                    entry.fullName, entry.id, entry.name, entry.description, entry.url.absoluteString,
                    entry.lastUpdated, date, date, date)
            }
        }
        notify(["catalogue"], repos: Set(entries.map(\.fullName)))
    }
}
