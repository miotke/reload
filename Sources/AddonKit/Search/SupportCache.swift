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
    /// A verdict younger than this is never re-checked.
    public static let defaultTTL: TimeInterval = 24 * 60 * 60
    /// Failed checks aren't retried for this long.
    public static let errorTTL: TimeInterval = 15 * 60

    public nonisolated let database: MetadataDatabase
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

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
    public func status(for ref: AddonRef, flavor: Flavor = .forever) async -> SupportStatus? {
        await record(for: ref, flavor: flavor)?.status
    }

    /// The stored verdict, including when it was checked and against which tag.
    public func record(for ref: AddonRef, flavor: Flavor = .forever) async -> SupportRecord? {
        let rows = (try? await database.query(
            "SELECT full_name, status, version, tag, checked_at FROM support WHERE full_name = ? AND flavor = ? AND status != 'error'",
            ref.identifier, flavor.rawValue)) ?? []
        return rows.first.flatMap(Self.record)
    }

    /// True when `ref` was checked (successfully or not) recently enough not to check again.
    public func isFresh(_ ref: AddonRef, flavor: Flavor = .forever) async -> Bool {
        guard let row = try? await database.query(
            "SELECT status, checked_at FROM support WHERE full_name = ? AND flavor = ?", ref.identifier, flavor.rawValue).first,
            let checked = row.date(1) else { return false }
        let age = now().timeIntervalSince(checked)
        return row.string(0) == "error" ? age < Self.errorTTL : age < ttl
    }

    /// Every stored verdict for `flavor`.
    public func statuses(flavor: Flavor = .forever) async -> [AddonRef: SupportStatus] {
        let rows = (try? await database.query(
            "SELECT full_name, status, version, tag, checked_at FROM support WHERE flavor = ? AND status != 'error'", flavor.rawValue)) ?? []
        var out: [AddonRef: SupportStatus] = [:]
        for record in rows.compactMap(Self.record) { out[record.ref] = record.status }
        return out
    }

    /// Stores one verdict. `.unknown` records a failed check; `.checking` is ignored.
    public func set(_ status: SupportStatus, for ref: AddonRef, flavor: Flavor = .forever, tag: String? = nil) async {
        await set([SupportRecord(ref: ref, status: status, tag: tag, checkedAt: now())], flavor: flavor)
    }

    /// Stores several verdicts in one transaction.
    public func set(_ records: [SupportRecord], flavor: Flavor = .forever) async {
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
            }
        }
        await database.notify(["support"], repos: Set(rows.map(\.0)))
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
