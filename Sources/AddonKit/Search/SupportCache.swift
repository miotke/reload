import Foundation

/// Persisted Forever-support verdicts per repo (docs/design.md §7.3), stored in
/// `forever-support.json` and trusted for 6 hours. `.checking` and `.unknown`
/// are transient and never stored.
public actor SupportCache {
    public static let fileName = "forever-support.json"
    public static let defaultTTL: TimeInterval = 6 * 60 * 60

    private struct Key: Hashable {
        var ref: AddonRef
        var flavor: Flavor
    }

    private struct Record {
        var status: SupportStatus
        var checkedAt: Date
    }

    private let fileURL: URL
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var records: [Key: Record] = [:]
    private var loaded = false

    public init(directory: URL, ttl: TimeInterval = SupportCache.defaultTTL, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = directory.appending(path: Self.fileName)
        self.ttl = ttl
        self.now = now
    }

    /// The cached status if it was checked within the TTL.
    public func status(for ref: AddonRef, flavor: Flavor = .forever) -> SupportStatus? {
        loadIfNeeded()
        guard let record = records[Key(ref: ref, flavor: flavor)], isFresh(record) else { return nil }
        return record.status
    }

    /// Every fresh status for `flavor`.
    public func statuses(flavor: Flavor = .forever) -> [AddonRef: SupportStatus] {
        loadIfNeeded()
        var out: [AddonRef: SupportStatus] = [:]
        for (key, record) in records where key.flavor == flavor && isFresh(record) {
            out[key.ref] = record.status
        }
        return out
    }

    public func set(_ status: SupportStatus, for ref: AddonRef, flavor: Flavor = .forever) {
        guard StoredStatus(status) != nil else { return }
        loadIfNeeded()
        records[Key(ref: ref, flavor: flavor)] = Record(status: status, checkedAt: now())
        save()
    }

    public func removeAll() {
        records = [:]
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func isFresh(_ record: Record) -> Bool {
        now().timeIntervalSince(record.checkedAt) < ttl
    }

    // MARK: Persistence

    private struct StoredStatus: Codable {
        enum Kind: String, Codable { case supported, unsupported, noReleases, needsDownload }
        var kind: Kind
        var version: String?

        init?(_ status: SupportStatus) {
            switch status {
            case .supported(let version): kind = .supported; self.version = version
            case .unsupported: kind = .unsupported
            case .noReleases: kind = .noReleases
            case .needsDownload: kind = .needsDownload
            case .unknown, .checking: return nil
            }
        }

        var status: SupportStatus {
            switch kind {
            case .supported: .supported(version: version ?? "")
            case .unsupported: .unsupported
            case .noReleases: .noReleases
            case .needsDownload: .needsDownload
            }
        }
    }

    private struct StoredEntry: Codable {
        var ref: AddonRef
        var flavor: Flavor
        var status: StoredStatus
        var checkedAt: Date
    }

    private struct StoredFile: Codable {
        var version = 1
        var entries: [StoredEntry]
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? Self.decoder().decode(StoredFile.self, from: data) else { return }
        for entry in file.entries {
            let key = Key(ref: entry.ref, flavor: entry.flavor)
            // Never let a file entry override something set in this session.
            if records[key] == nil {
                records[key] = Record(status: entry.status.status, checkedAt: entry.checkedAt)
            }
        }
    }

    private func save() {
        let entries = records.compactMap { key, record -> StoredEntry? in
            guard isFresh(record), let stored = StoredStatus(record.status) else { return nil }
            return StoredEntry(ref: key.ref, flavor: key.flavor, status: stored, checkedAt: record.checkedAt)
        }
        .sorted { ($0.ref.description, $0.flavor.rawValue) < ($1.ref.description, $1.flavor.rawValue) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(StoredFile(entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
