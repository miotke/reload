import Foundation

/// The WoWInterface and Tukui listings and latest files, kept in the metadata database
/// (docs/features/sources.md). The single owner of hosted freshness:
///
/// - A listing is trusted for 24 h, like the GitHub catalogue, and after a failed download
///   isn't tried again for 15 minutes. Its rows go into `catalogue` under `AddonRef.key`.
/// - A latest file (download link, version, notes) is trusted for 1 h, the same lifetime as
///   a GitHub verdict, so the 2-hour refresh always sees new versions of installed add-ons.
public actor HostedCatalogue {
    public static let maxAge: TimeInterval = 24 * 60 * 60
    public static let failureBackoff: TimeInterval = 15 * 60
    public static let fileTTL: TimeInterval = SupportCache.defaultTTL
    /// IDs per batched files request; keeps the URL short.
    public static let batchSize = 50

    private let http: any HTTPClient
    private let database: MetadataDatabase
    private let catalogue: CatalogueSource
    private let sources: [any HostedSource]
    private var now: @Sendable () -> Date
    private var inFlight: [SourceID: Task<Bool, any Error>] = [:]

    init(
        http: any HTTPClient, database: MetadataDatabase, catalogue: CatalogueSource,
        sources: [any HostedSource] = HostedSources.all, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.database = database
        self.catalogue = catalogue
        self.sources = sources
        self.now = now
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) {
        now = clock
    }

    private func source(_ id: SourceID) throws -> any HostedSource {
        guard let source = sources.first(where: { $0.id == id }) else { throw AddonError.invalidReference(id.rawValue) }
        return source
    }

    // MARK: - Listings

    /// Downloads `id`'s listing when the stored one is older than 24 h (or always with
    /// `force`, which also skips the failure backoff). Returns true when it downloaded.
    @discardableResult
    public func refresh(_ id: SourceID, force: Bool = false) async throws -> Bool {
        if let running = inFlight[id] { return try await running.value }
        let state = try await database.sourceState(id)
        let current = now()
        if !force {
            if let failed = state.failedAt, current.timeIntervalSince(failed) < Self.failureBackoff { return false }
            if let fetched = state.fetchedAt, current.timeIntervalSince(fetched) < Self.maxAge { return false }
        }
        let task = Task { try await self.download(id, state: state) }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        return try await task.value
    }

    /// True when `id`'s listing has never been downloaded and no failed attempt is within
    /// the 15-minute backoff, so a refresh would try it now.
    public func isMissing(_ id: SourceID) async -> Bool {
        guard let state = try? await database.sourceState(id), state.fetchedAt == nil else { return false }
        guard let failed = state.failedAt else { return true }
        return now().timeIntervalSince(failed) >= Self.failureBackoff
    }

    /// When `id`'s listing was last downloaded, if ever.
    public func lastFetched(_ id: SourceID) async -> Date? {
        try? await database.sourceState(id).fetchedAt
    }

    private func download(_ id: SourceID, state: CatalogueState) async throws -> Bool {
        let source = try source(id)
        var request = URLRequest(url: source.listingURL)
        if let etag = state.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await http.data(for: request)
            switch response.statusCode {
            case 304:
                try await database.setSourceState(id, etag: state.etag, fetchedAt: now(), failedAt: nil)
                return false
            case 200:
                // Decoding ~5 MB of JSON stays off this actor's executor.
                let entries = try await Self.parse(source, data)
                guard !entries.isEmpty else { throw AddonError.http(status: 200, url: source.listingURL) }
                try await database.importHostedListing(
                    entries, source: id, etag: response.value(forHTTPHeaderField: "ETag"), at: now())
                await catalogue.invalidate()
                return true
            default:
                throw AddonError.http(status: response.statusCode, url: source.listingURL)
            }
        } catch {
            try? await database.setSourceState(id, etag: state.etag, fetchedAt: state.fetchedAt, failedAt: now())
            throw error
        }
    }

    @concurrent
    private static func parse(_ source: any HostedSource, _ data: Data) async throws -> [CatalogueEntry] {
        try source.entries(fromListing: data)
    }

    // MARK: - Latest files

    /// Fetches the latest files of `refs` that `policy` says are due, one request per host
    /// per `batchSize` IDs instead of one per add-on: a bulk update check of ten WoWInterface
    /// add-ons is one request. Afterwards their stored files are fresh, so `file(for:policy:)`
    /// with `.revalidateIfStale` needs no request. Failures are skipped; those add-ons are
    /// asked for one at a time by their own check.
    public func prefetch(_ refs: [AddonRef], policy: CachePolicy) async {
        guard policy != .preferStored else { return }
        var due: [SourceID: [String]] = [:]
        for ref in refs where ref.source != .github {
            if policy == .revalidateIfStale, let stored = await database.hostedFile(ref),
               now().timeIntervalSince(stored.fetchedAt) < Self.fileTTL { continue }
            due[ref.source, default: []].append(ref.identifier)
        }
        for (id, identifiers) in due.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let source = try? source(id) else { continue }
            let sorted = Array(Set(identifiers)).sorted()
            for start in stride(from: 0, to: sorted.count, by: Self.batchSize) {
                let batch = Array(sorted[start..<min(start + Self.batchSize, sorted.count)])
                guard let (data, response) = try? await http.data(for: URLRequest(url: source.filesURL(for: batch))),
                      response.statusCode == 200, let files = try? source.files(from: data) else { continue }
                await database.setHostedFiles(Array(files.values), source: id, at: now())
            }
        }
    }

    /// `ref`'s latest file. `.preferStored` uses any stored answer and only asks when there
    /// is none; `.revalidateIfStale` asks once the stored one is an hour old;
    /// `.forceRevalidate` always asks. Throws `AddonError.notFound` when the host has no such file.
    public func file(for ref: AddonRef, policy: CachePolicy) async throws -> HostedFile {
        let stored = await database.hostedFile(ref)
        if let stored {
            switch policy {
            case .preferStored:
                return stored.file
            case .revalidateIfStale where now().timeIntervalSince(stored.fetchedAt) < Self.fileTTL:
                return stored.file
            default:
                break
            }
        }
        let source = try source(ref.source)
        let (data, response) = try await http.data(for: URLRequest(url: source.filesURL(for: [ref.identifier])))
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw AddonError.notFound(ref) }
            throw AddonError.http(status: response.statusCode, url: response.url ?? source.listingURL)
        }
        let files = try source.files(from: data)
        // Tukui answers with every add-on; keep them all, it's the same request.
        await database.setHostedFiles(Array(files.values), source: ref.source, at: now())
        guard let file = files[ref.identifier] ?? files.first(where: { $0.key.caseInsensitiveCompare(ref.identifier) == .orderedSame })?.value else {
            throw AddonError.notFound(ref)
        }
        return file
    }
}

// MARK: - Database access

extension MetadataDatabase {
    func sourceState(_ source: SourceID) throws -> CatalogueState {
        guard let row = try query("SELECT etag, fetched_at, failed_at FROM source_state WHERE source = ?", source.rawValue).first else {
            return CatalogueState()
        }
        return CatalogueState(etag: row.string(0), fetchedAt: row.date(1), failedAt: row.date(2))
    }

    func setSourceState(_ source: SourceID, etag: String?, fetchedAt: Date?, failedAt: Date?) throws {
        try execute("""
            INSERT INTO source_state(source, etag, fetched_at, failed_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(source) DO UPDATE SET etag = excluded.etag, fetched_at = excluded.fetched_at, failed_at = excluded.failed_at
            """, source.rawValue, etag, fetchedAt, failedAt)
    }

    /// Upserts a host's listing in one transaction, skipping unchanged rows, and deletes that
    /// host's rows the listing no longer has. Other sources' rows are never touched.
    func importHostedListing(_ entries: [CatalogueEntry], source: SourceID, etag: String?, at date: Date) throws {
        let changed = try transaction { db in
            var changed = Set<String>()
            var listed = Set<String>()
            let upsert = try db.prepare("""
                INSERT INTO catalogue(\(Self.catalogueColumns), first_seen_at, seen_at, changed_at, author, screenshots_json, folders_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 0, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(full_name) DO UPDATE SET
                    id = excluded.id, name = excluded.name, description = excluded.description, url = excluded.url,
                    last_updated = excluded.last_updated, flavors = excluded.flavors, author = excluded.author,
                    screenshots_json = excluded.screenshots_json, folders_json = excluded.folders_json,
                    seen_at = excluded.seen_at, changed_at = excluded.changed_at
                WHERE catalogue.source = excluded.source
                    AND (catalogue.id, catalogue.name, catalogue.description, catalogue.url, catalogue.last_updated,
                         catalogue.flavors, catalogue.author, catalogue.screenshots_json, catalogue.folders_json)
                    IS NOT (excluded.id, excluded.name, excluded.description, excluded.url, excluded.last_updated,
                            excluded.flavors, excluded.author, excluded.screenshots_json, excluded.folders_json)
                """)
            let seen = date.sqlValue
            for entry in entries {
                listed.insert(entry.fullName.lowercased())
                let screenshots = (entry.screenshots ?? []).isEmpty ? nil
                    : (try? JSONEncoder().encode((entry.screenshots ?? []).map(\.absoluteString))).map { String(decoding: $0, as: UTF8.self) }
                let folders = (entry.folders ?? []).isEmpty ? nil
                    : (try? JSONEncoder().encode(entry.folders ?? [])).map { String(decoding: $0, as: UTF8.self) }
                let count = try db.step(upsert, [
                    .text(entry.fullName), .text(entry.id), .text(entry.name), entry.description.sqlValue,
                    .text(entry.url.absoluteString), entry.lastUpdated.sqlValue, .text(entry.flavors.joined(separator: ",")),
                    .text(source.rawValue), seen, seen, seen, entry.author.sqlValue, screenshots.sqlValue, folders.sqlValue,
                ])
                if count > 0 { changed.insert(entry.fullName) }
            }
            for row in try db.query("SELECT full_name FROM catalogue WHERE source = ?", source.rawValue) {
                guard let name = row.string(0), !listed.contains(name.lowercased()) else { continue }
                try db.execute("DELETE FROM catalogue WHERE full_name = ?", name)
                changed.insert(name)
            }
            try db.setSourceState(source, etag: etag, fetchedAt: date, failedAt: nil)
            return changed
        }
        // A first import changes thousands of rows: report "many" rather than listing them.
        if !changed.isEmpty { notify(["catalogue"], repos: changed.count > 500 ? [] : changed) }
    }

    func hostedFile(_ ref: AddonRef) -> (file: HostedFile, fetchedAt: Date)? {
        guard let row = try? query("SELECT json, fetched_at FROM hosted_files WHERE full_name = ?", ref.key).first,
              let json = row.string(0), let fetched = row.date(1),
              let file = try? JSONDecoder().decode(HostedFile.self, from: Data(json.utf8)) else { return nil }
        return (file, fetched)
    }

    func setHostedFiles(_ files: [HostedFile], source: SourceID, at date: Date) {
        let rows: [(String, String)] = files.compactMap { file in
            let key = AddonRef(source: source, identifier: file.identifier).key
            return (try? JSONEncoder().encode(file)).map { (key, String(decoding: $0, as: UTF8.self)) }
        }
        _ = try? transaction { db in
            for (key, json) in rows {
                try db.execute("""
                    INSERT INTO hosted_files(full_name, json, fetched_at) VALUES (?, ?, ?)
                    ON CONFLICT(full_name) DO UPDATE SET json = excluded.json, fetched_at = excluded.fetched_at
                    """, key, json, date)
            }
        }
    }
}
