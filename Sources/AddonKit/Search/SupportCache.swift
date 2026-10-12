import Foundation

/// A stored support verdict for one repo and flavor.
public struct SupportRecord: Sendable, Hashable {
    public var ref: AddonRef
    public var status: SupportStatus
    /// Latest release tag the verdict was based on, when known.
    public var tag: String?
    public var checkedAt: Date
    /// Every flavor `tag`'s release.json names, when it was read for this verdict. Stored per
    /// repo in the same transaction; nil leaves what's stored alone.
    public var availableFlavors: Set<Flavor>?

    public init(ref: AddonRef, status: SupportStatus, tag: String? = nil, checkedAt: Date, availableFlavors: Set<Flavor>? = nil) {
        self.ref = ref
        self.status = status
        self.tag = tag
        self.checkedAt = checkedAt
        self.availableFlavors = availableFlavors
    }
}

/// Every flavor a repo's latest release ships, as stored in `repo_meta` (decision 0019).
public struct StoredFlavors: Sendable, Hashable {
    public enum Source: String, Sendable {
        /// The release's release.json: authoritative for `tag`.
        case releaseJSON = "release_json"
        /// The TOCs of a zip that was installed or adopted, for repos without a release.json.
        case inspection
    }

    public var flavors: Set<Flavor>
    /// The release these flavors describe.
    public var tag: String?
    public var source: Source
}

/// Per-repo knowledge kept in the metadata database: Forever-support verdicts (`support`
/// table) and repo metadata such as the latest tag and stars (`repo_meta`). See docs/features/search.md.
///
/// - A verdict is shown for as long as it's stored; `isFresh` decides when to re-check.
/// - A failed check is recorded beside the last good verdict (`error_at`, `retry_after`),
///   never over it, and isn't retried for 15 minutes.
/// - `.checking` is never stored.
/// - Decoded release.json files are kept by `repo@tag` (`release_json`), and the last API
///   call per repo is timed (`repo_meta.api_checked_at`).
public actor SupportCache {
    /// The JSON file earlier versions wrote to the caches folder. No longer used.
    public static let fileName = "forever-support.json"
    /// How long `.revalidateIfStale` reuses a verdict for a repo with releases. Short enough
    /// that the 2-hour background refresh sees new tags of installed add-ons.
    public static let defaultTTL: TimeInterval = 60 * 60
    /// How long a negative answer (no releases, repo gone) is reused.
    public static let negativeTTL: TimeInterval = 24 * 60 * 60
    /// Failed checks aren't retried for this long.
    public static let errorTTL: TimeInterval = 15 * 60
    /// A repo's latest tag, stored by any flavor's check, is reused this long by the others.
    public static let sharedTagTTL: TimeInterval = 60 * 60
    /// Background and bulk update checks call the API for a repo at most this often.
    public static let apiCheckInterval: TimeInterval = 6 * 60 * 60

    /// A stored row as `LatestReleaseStore.latestRelease` sees it.
    struct StoredSupport: Sendable {
        /// Nil when no check has ever succeeded.
        var status: SupportStatus?
        var tag: String?
        /// When `status` was decided.
        var checkedAt: Date?
        /// The last check failed, at this time; cleared by the next success.
        var errorAt: Date?
        var retryAfter: Date?
    }

    public nonisolated let database: MetadataDatabase
    private let ttl: TimeInterval
    private var now: @Sendable () -> Date

    public init(database: MetadataDatabase, ttl: TimeInterval = SupportCache.defaultTTL, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.ttl = ttl
        self.now = now
    }

    /// Opens (or creates) the metadata database in `directory`. Prefer `init(database:)`.
    public init(directory: URL, ttl: TimeInterval = SupportCache.defaultTTL, now: @escaping @Sendable () -> Date = Date.init) {
        let database = (try? MetadataDatabase(url: directory.appending(path: MetadataDatabase.fileName)))
            ?? (try! MetadataDatabase.inMemory())
        self.init(database: database, ttl: ttl, now: now)
    }

    // MARK: - Verdicts

    /// The stored verdict, however old. Nil when never checked or the last check failed.
    public func status(for ref: AddonRef, flavor: Flavor) async -> SupportStatus? {
        await record(for: ref, flavor: flavor)?.status
    }

    /// The stored verdict, including when it was checked and against which tag.
    public func record(for ref: AddonRef, flavor: Flavor) async -> SupportRecord? {
        let rows = (try? await database.query(
            "SELECT full_name, status, version, tag, checked_at FROM support WHERE full_name = ? AND flavor = ? AND status IS NOT NULL",
            ref.identifier, flavor.rawValue)) ?? []
        return rows.first.flatMap(Self.record)
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) {
        now = clock
    }

    func storedSupport(for ref: AddonRef, flavor: Flavor) async -> StoredSupport? {
        guard let row = try? await database.query(
            "SELECT status, version, tag, checked_at, error_at, retry_after FROM support WHERE full_name = ? AND flavor = ?",
            ref.identifier, flavor.rawValue).first else { return nil }
        return StoredSupport(
            status: row.string(0).flatMap { Self.status(kind: $0, version: row.string(1)) },
            tag: row.string(2), checkedAt: row.date(3), errorAt: row.date(4), retryAfter: row.date(5))
    }

    /// Whether a stored answer is within its lifetime: verdicts 1 h, negative answers 24 h,
    /// and nothing is retried within 15 min of a failure. Only `LatestReleaseStore.latestRelease`
    /// decides with this.
    func isFresh(_ stored: StoredSupport) -> Bool {
        if let retry = stored.retryAfter, retry > now() { return true }
        guard let status = stored.status, let checked = stored.checkedAt else { return false }
        let age = now().timeIntervalSince(checked)
        if case .noReleases = status { return age < Self.negativeTTL }
        return age < ttl
    }

    /// Every stored verdict for `flavor`.
    public func statuses(flavor: Flavor) async -> [AddonRef: SupportStatus] {
        let rows = (try? await database.query(
            "SELECT full_name, status, version, tag, checked_at FROM support WHERE flavor = ? AND status IS NOT NULL", flavor.rawValue)) ?? []
        var out: [AddonRef: SupportStatus] = [:]
        for record in rows.compactMap(Self.record) { out[record.ref] = record.status }
        return out
    }

    /// Stores one verdict. `.unknown` records a failed check; `.checking` is ignored.
    public func set(_ status: SupportStatus, for ref: AddonRef, flavor: Flavor, tag: String? = nil) async {
        await set([SupportRecord(ref: ref, status: status, tag: tag, checkedAt: now())], flavor: flavor)
    }

    /// Stores several verdicts in one transaction. A `.unknown` record is a failed check: it
    /// leaves any stored verdict and tag alone and only schedules the retry.
    public func set(_ records: [SupportRecord], flavor: Flavor) async {
        let flavorName = SQLValue.text(flavor.rawValue)
        var verdicts: [[SQLValue]] = []
        var tags: [[SQLValue]] = []
        var failures: [[SQLValue]] = []
        var flavorRows: [[SQLValue]] = []
        var changed: Set<String> = []
        for record in records {
            let name = SQLValue.text(record.ref.identifier)
            if let available = record.availableFlavors {
                flavorRows.append([name, .text(available.storageValue), record.tag.sqlValue, .text(StoredFlavors.Source.releaseJSON.rawValue)])
            }
            if case .unknown = record.status {
                failures.append([name, flavorName, record.checkedAt.sqlValue,
                                 record.checkedAt.addingTimeInterval(Self.errorTTL).sqlValue])
                continue
            }
            guard let kind = Self.kind(record.status) else { continue }
            changed.insert(record.ref.identifier)
            verdicts.append([name, flavorName, .text(kind), Self.version(record.status).sqlValue,
                             record.tag.sqlValue, record.checkedAt.sqlValue])
            // A verdict with a tag also tells us the latest tag; a negative one, that there's none.
            if record.tag != nil || kind == "noReleases" {
                tags.append([name, record.tag.sqlValue, record.checkedAt.sqlValue])
            }
        }
        guard !verdicts.isEmpty || !failures.isEmpty else { return }
        let (verdictRows, tagRows, failureRows, availableRows) = (verdicts, tags, failures, flavorRows)
        _ = try? await database.transaction { db in
            if !verdictRows.isEmpty {
                let upsert = try db.prepare("""
                    INSERT INTO support(full_name, flavor, status, version, tag, checked_at) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(full_name, flavor) DO UPDATE SET
                        status = excluded.status, version = excluded.version,
                        tag = coalesce(excluded.tag, support.tag), checked_at = excluded.checked_at,
                        error_at = NULL, retry_after = NULL
                    """)
                for row in verdictRows { try db.step(upsert, row) }
            }
            if !tagRows.isEmpty {
                let upsert = try db.prepare("""
                    INSERT INTO repo_meta(full_name, latest_tag, tag_checked_at) VALUES (?, ?, ?)
                    ON CONFLICT(full_name) DO UPDATE SET
                        latest_published_at = CASE WHEN repo_meta.latest_tag IS excluded.latest_tag
                            THEN repo_meta.latest_published_at ELSE NULL END,
                        latest_tag = excluded.latest_tag, tag_checked_at = excluded.tag_checked_at
                    """)
                for row in tagRows { try db.step(upsert, row) }
            }
            if !failureRows.isEmpty {
                let upsert = try db.prepare("""
                    INSERT INTO support(full_name, flavor, error_at, retry_after) VALUES (?, ?, ?, ?)
                    ON CONFLICT(full_name, flavor) DO UPDATE SET error_at = excluded.error_at, retry_after = excluded.retry_after
                    """)
                for row in failureRows { try db.step(upsert, row) }
            }
            if !availableRows.isEmpty {
                let upsert = try db.prepare(Self.upsertFlavorsSQL)
                for row in availableRows { try db.step(upsert, row) }
            }
        }
        // A failure changes nothing anyone shows.
        guard !changed.isEmpty else { return }
        await database.notify(["support", "repo_meta"], repos: changed)
    }

    public func removeAll() async {
        _ = try? await database.transaction { db in
            try db.execute("DELETE FROM support")
            try db.execute("DELETE FROM repo_meta")
            try db.execute("DELETE FROM details")
            try db.execute("DELETE FROM release_json")
        }
        await database.notify(["support", "repo_meta", "details"])
    }

    // MARK: - Available flavors

    /// Writes nothing when unchanged, and an inspection never replaces what a release.json said.
    static let upsertFlavorsSQL = """
        INSERT INTO repo_meta(full_name, available_flavors, flavors_tag, flavors_source) VALUES (?, ?, ?, ?)
        ON CONFLICT(full_name) DO UPDATE SET available_flavors = excluded.available_flavors,
            flavors_tag = excluded.flavors_tag, flavors_source = excluded.flavors_source
        WHERE (repo_meta.available_flavors, repo_meta.flavors_tag, repo_meta.flavors_source)
                IS NOT (excluded.available_flavors, excluded.flavors_tag, excluded.flavors_source)
            AND (excluded.flavors_source = 'release_json' OR repo_meta.flavors_source IS NOT 'release_json')
        """

    /// What `ref`'s latest release ships, as stored; nil when nobody has looked.
    public func storedFlavors(for ref: AddonRef) async -> StoredFlavors? {
        guard let row = try? await database.query(
            "SELECT available_flavors, flavors_tag, flavors_source FROM repo_meta WHERE full_name = ?", ref.identifier).first,
            let text = row.string(0), let source = row.string(2).flatMap(StoredFlavors.Source.init(rawValue:)) else { return nil }
        return StoredFlavors(flavors: Set(storageValue: text), tag: row.string(1), source: source)
    }

    public func availableFlavors(for ref: AddonRef) async -> Set<Flavor>? {
        await storedFlavors(for: ref)?.flavors
    }

    /// The stored verdict for `flavor` and the stored flavors of each repo in `refs`, in one
    /// query: Browse patches up to 500 rows at a time, and two lookups per row cost ~6×
    /// as much. Keyed by lower-cased `owner/repo`; repos with neither are left out.
    func storedAvailability(for refs: [AddonRef], flavor: Flavor) async -> [String: (support: SupportStatus?, flavors: Set<Flavor>?)] {
        let names = Array(Set(refs.map { $0.identifier.lowercased() }))
        guard !names.isEmpty, let list = try? JSONEncoder().encode(names) else { return [:] }
        let rows = (try? await database.query("""
            SELECT r.value, s.status, s.version, s.checked_at, m.available_flavors, m.flavors_source
            FROM json_each(?) r
            LEFT JOIN support s ON s.full_name = r.value AND s.flavor = ? AND s.status IS NOT NULL
            LEFT JOIN repo_meta m ON m.full_name = r.value
            """, String(decoding: list, as: UTF8.self), flavor.rawValue)) ?? []
        var out: [String: (support: SupportStatus?, flavors: Set<Flavor>?)] = [:]
        for row in rows {
            guard let name = row.string(0) else { continue }
            // The same rules as `record(for:flavor:)` and `storedFlavors(for:)`.
            let support = row.date(3) == nil ? nil : row.string(1).flatMap { Self.status(kind: $0, version: row.string(2)) }
            let flavors = row.string(5).flatMap(StoredFlavors.Source.init(rawValue:)) == nil
                ? nil : row.string(4).map { Set<Flavor>(storageValue: $0) }
            if support != nil || flavors != nil { out[name] = (support, flavors) }
        }
        return out
    }

    /// Every stored answer, keyed by lower-cased `owner/repo`: one query per search.
    public func allAvailableFlavors() async -> [String: Set<Flavor>] {
        let rows = (try? await database.query(
            "SELECT full_name, available_flavors FROM repo_meta WHERE available_flavors IS NOT NULL")) ?? []
        var out: [String: Set<Flavor>] = [:]
        for row in rows {
            if let name = row.string(0), let text = row.string(1) { out[name.lowercased()] = Set(storageValue: text) }
        }
        return out
    }

    /// Records what `tag` ships. `nil` from a release.json source means that release has none:
    /// flavors an older release.json gave are cleared, an inspection's are kept.
    public func setAvailableFlavors(_ flavors: Set<Flavor>?, tag: String?, source: StoredFlavors.Source, for ref: AddonRef) async {
        let changed: Int
        if let flavors {
            changed = (try? await database.execute(Self.upsertFlavorsSQL, ref.identifier, flavors.storageValue, tag, source.rawValue)) ?? 0
        } else {
            guard source == .releaseJSON else { return }
            changed = (try? await database.execute("""
                UPDATE repo_meta SET available_flavors = NULL, flavors_tag = NULL, flavors_source = NULL
                WHERE full_name = ? AND flavors_source = 'release_json'
                """, ref.identifier)) ?? 0
        }
        if changed > 0 { await database.notify(["repo_meta"], repos: [ref.identifier]) }
    }

    // MARK: - Repo metadata

    /// The latest release tag last seen for `ref`, and when.
    public func latestTag(for ref: AddonRef) async -> (tag: String?, checkedAt: Date)? {
        guard let row = try? await database.query(
            "SELECT latest_tag, tag_checked_at FROM repo_meta WHERE full_name = ?", ref.identifier).first,
            let checked = row.date(1) else { return nil }
        return (row.string(0), checked)
    }

    /// Records the latest stable tag (nil: no releases), and its publish date when known.
    public func setLatestTag(_ tag: String?, publishedAt: Date? = nil, for ref: AddonRef) async {
        _ = try? await database.execute("""
            INSERT INTO repo_meta(full_name, latest_tag, tag_checked_at, latest_published_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(full_name) DO UPDATE SET
                latest_published_at = CASE WHEN repo_meta.latest_tag IS excluded.latest_tag
                    THEN coalesce(excluded.latest_published_at, repo_meta.latest_published_at)
                    ELSE excluded.latest_published_at END,
                latest_tag = excluded.latest_tag, tag_checked_at = excluded.tag_checked_at
            """, ref.identifier, tag, now(), publishedAt)
    }

    /// Records when the stored latest tag was published, once an API call reveals it. Never
    /// changes the tag itself: that's `LatestReleaseStore.check`'s job.
    public func setPublishedAt(_ date: Date, ifLatestTagIs tag: String, for ref: AddonRef) async {
        _ = try? await database.execute(
            "UPDATE repo_meta SET latest_published_at = ? WHERE full_name = ? AND latest_tag = ?", date, ref.identifier, tag)
    }

    /// Publish date of the stored latest tag, when an API call has revealed it.
    public func latestPublishedAt(for ref: AddonRef) async -> Date? {
        try? await database.query("SELECT latest_published_at FROM repo_meta WHERE full_name = ?", ref.identifier).first?.date(0)
    }

    /// release.json of `ref`'s release `tag` as stored: nil when it was never fetched,
    /// `.some(nil)` when that release has none. Tags are effectively immutable, so these
    /// never expire; `removeAll` clears them.
    func releaseJSON(for ref: AddonRef, tag: String) async -> ReleaseJSON?? {
        guard let row = try? await database.query(
            "SELECT json FROM release_json WHERE full_name = ? AND tag = ?", ref.identifier, tag).first else { return nil }
        guard let text = row.string(0) else { return .some(nil) }
        // An undecodable row is as good as missing: it's fetched again.
        return (try? ReleaseJSON(data: Data(text.utf8))).map { .some($0) }
    }

    func setReleaseJSON(_ json: ReleaseJSON?, for ref: AddonRef, tag: String) async {
        let text = json.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        _ = try? await database.execute("""
            INSERT INTO release_json(full_name, tag, json, fetched_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(full_name, tag) DO UPDATE SET json = excluded.json, fetched_at = excluded.fetched_at
            """, ref.identifier, tag, text, now())
    }

    /// When the API was last asked about `ref`'s releases, and the latest stable tag known then.
    func apiCheck(for ref: AddonRef) async -> (at: Date, latestTag: String?)? {
        guard let row = try? await database.query(
            "SELECT api_checked_at, api_checked_tag FROM repo_meta WHERE full_name = ?", ref.identifier).first,
            let at = row.date(0) else { return nil }
        return (at, row.string(1))
    }

    /// Records an API call for `ref`, with the latest tag as it's stored now.
    func setAPIChecked(at date: Date, for ref: AddonRef) async {
        _ = try? await database.execute("""
            INSERT INTO repo_meta(full_name, api_checked_at) VALUES (?, ?)
            ON CONFLICT(full_name) DO UPDATE SET api_checked_at = excluded.api_checked_at, api_checked_tag = repo_meta.latest_tag
            """, ref.identifier, date)
    }

    /// Star counts seen in live GitHub results, keyed by lower-cased `owner/repo`.
    public func stars() async -> [String: Int] {
        let rows = (try? await database.query("SELECT full_name, stars FROM repo_meta WHERE stars IS NOT NULL")) ?? []
        var out: [String: Int] = [:]
        for row in rows { if let name = row.string(0), let stars = row.int(1) { out[name.lowercased()] = stars } }
        return out
    }

    public func setStars(_ stars: [AddonRef: Int]) async {
        guard !stars.isEmpty else { return }
        let pairs = stars.map { ($0.key.identifier, $0.value) }
        _ = try? await database.transaction { db in
            for (name, count) in pairs {
                try db.execute("""
                    INSERT INTO repo_meta(full_name, stars) VALUES (?, ?)
                    ON CONFLICT(full_name) DO UPDATE SET stars = excluded.stars WHERE repo_meta.stars IS NOT excluded.stars
                    """, name, count)
            }
        }
    }

    // MARK: - Encoding

    static func kind(_ status: SupportStatus) -> String? {
        switch status {
        case .supported: "supported"
        case .unsupported: "unsupported"
        case .noReleases: "noReleases"
        case .needsDownload: "needsDownload"
        case .unknown: "error"
        case .checking: nil
        }
    }

    static func version(_ status: SupportStatus) -> String? {
        if case .supported(let version) = status { return version }
        return nil
    }

    static func status(kind: String, version: String?) -> SupportStatus? {
        switch kind {
        case "supported": .supported(version: version ?? "")
        case "unsupported": .unsupported
        case "noReleases": .noReleases
        case "needsDownload": .needsDownload
        default: nil
        }
    }

    static func record(_ row: SQLRow) -> SupportRecord? {
        guard let name = row.string(0), let kind = row.string(1),
              let status = status(kind: kind, version: row.string(2)), let checked = row.date(4) else { return nil }
        return SupportRecord(ref: AddonRef(source: .github, identifier: name), status: status, tag: row.string(3), checkedAt: checked)
    }
}
