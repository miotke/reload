import Foundation

/// A stored support verdict for one repo and flavor.
public struct SupportRecord: Sendable, Hashable {
    public var ref: AddonRef
    public var status: SupportStatus
    /// Latest release tag the verdict was based on, when known.
    public var tag: String?
    public var checkedAt: Date

    public init(ref: AddonRef, status: SupportStatus, tag: String? = nil, checkedAt: Date) {
        self.ref = ref
        self.status = status
        self.tag = tag
        self.checkedAt = checkedAt
    }
}

/// Per-repo knowledge kept in the metadata database: Forever-support verdicts (`support`
/// table) and repo metadata such as the latest tag and stars (`repo_meta`). See docs/search.md.
///
/// - A verdict is shown for as long as it's stored; `isFresh` decides when to re-check.
/// - A failed check is stored as an error for 15 minutes so it isn't retried on every view.
/// - `.checking` is never stored.
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

    /// A stored row as `GitHubSource.latestRelease` sees it.
    struct StoredSupport: Sendable {
        /// Nil for a failed check.
        var status: SupportStatus?
        var tag: String?
        var checkedAt: Date
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
            "SELECT full_name, status, version, tag, checked_at FROM support WHERE full_name = ? AND flavor = ? AND status != 'error'",
            ref.identifier, flavor.rawValue)) ?? []
        return rows.first.flatMap(Self.record)
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) {
        now = clock
    }

    func storedSupport(for ref: AddonRef, flavor: Flavor) async -> StoredSupport? {
        guard let row = try? await database.query(
            "SELECT status, version, tag, checked_at FROM support WHERE full_name = ? AND flavor = ?",
            ref.identifier, flavor.rawValue).first,
            let kind = row.string(0), let checked = row.date(3) else { return nil }
        return StoredSupport(status: Self.status(kind: kind, version: row.string(1)), tag: row.string(2), checkedAt: checked)
    }

    /// Whether a stored answer is within its lifetime: verdicts 1 h, negative answers 24 h,
    /// failures 15 min. Only `GitHubSource.latestRelease` decides with this.
    func isFresh(_ stored: StoredSupport) -> Bool {
        let age = now().timeIntervalSince(stored.checkedAt)
        switch stored.status {
        case nil: return age < Self.errorTTL
        case .noReleases?: return age < Self.negativeTTL
        default: return age < ttl
        }
    }

    /// Every stored verdict for `flavor`.
    public func statuses(flavor: Flavor) async -> [AddonRef: SupportStatus] {
        let rows = (try? await database.query(
            "SELECT full_name, status, version, tag, checked_at FROM support WHERE flavor = ? AND status != 'error'", flavor.rawValue)) ?? []
        var out: [AddonRef: SupportStatus] = [:]
        for record in rows.compactMap(Self.record) { out[record.ref] = record.status }
        return out
    }

    /// Stores one verdict. `.unknown` records a failed check; `.checking` is ignored.
    public func set(_ status: SupportStatus, for ref: AddonRef, flavor: Flavor, tag: String? = nil) async {
        await set([SupportRecord(ref: ref, status: status, tag: tag, checkedAt: now())], flavor: flavor)
    }

    /// Stores several verdicts in one transaction.
    public func set(_ records: [SupportRecord], flavor: Flavor) async {
        let rows = records.compactMap { record -> (String, String, String?, String?, Date)? in
            guard let kind = Self.kind(record.status) else { return nil }
            return (record.ref.identifier, kind, Self.version(record.status), record.tag, record.checkedAt)
        }
        guard !rows.isEmpty else { return }
        let flavorName = flavor.rawValue
        _ = try? await database.transaction { db in
            for row in rows {
                try db.execute("""
                    INSERT INTO support(full_name, flavor, status, version, tag, checked_at) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(full_name, flavor) DO UPDATE SET
                        status = excluded.status, version = excluded.version,
                        tag = coalesce(excluded.tag, support.tag), checked_at = excluded.checked_at
                    """, row.0, flavorName, row.1, row.2, row.3, row.4)
                // A verdict with a tag also tells us the latest tag; a negative one, that
                // there's none.
                if row.3 != nil || row.1 == "noReleases" {
                    try db.execute("""
                        INSERT INTO repo_meta(full_name, latest_tag, tag_checked_at) VALUES (?, ?, ?)
                        ON CONFLICT(full_name) DO UPDATE SET
                            latest_published_at = CASE WHEN repo_meta.latest_tag IS excluded.latest_tag
                                THEN repo_meta.latest_published_at ELSE NULL END,
                            latest_tag = excluded.latest_tag, tag_checked_at = excluded.tag_checked_at
                        """, row.0, row.3, row.4)
                }
            }
        }
        await database.notify(["support", "repo_meta"], repos: Set(rows.map(\.0)))
    }

    public func removeAll() async {
        _ = try? await database.transaction { db in
            try db.execute("DELETE FROM support")
            try db.execute("DELETE FROM repo_meta")
            try db.execute("DELETE FROM details")
        }
        await database.notify(["support", "repo_meta", "details"])
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
    /// changes the tag itself: that's `GitHubSource.check`'s job.
    public func setPublishedAt(_ date: Date, ifLatestTagIs tag: String, for ref: AddonRef) async {
        _ = try? await database.execute(
            "UPDATE repo_meta SET latest_published_at = ? WHERE full_name = ? AND latest_tag = ?", date, ref.identifier, tag)
    }

    /// Publish date of the stored latest tag, when an API call has revealed it.
    public func latestPublishedAt(for ref: AddonRef) async -> Date? {
        try? await database.query("SELECT latest_published_at FROM repo_meta WHERE full_name = ?", ref.identifier).first?.date(0)
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
