import AddonKit
import Foundation

/// A sortable table column. Raw values are persisted, so don't rename cases.
nonisolated protocol SortableColumn: RawRepresentable<String>, Hashable, Sendable {
    associatedtype Row
    /// Ascending order of two rows that both have a value for this column.
    func ascending(_ lhs: Row, _ rhs: Row) -> ComparisonResult
    /// Rows without a value (no stars, never checked…) sort last in either direction.
    func hasValue(_ row: Row) -> Bool
    /// Breaks ties, always ascending, so equal rows keep a predictable order.
    static func tiebreak(_ lhs: Row, _ rhs: Row) -> ComparisonResult
}

/// The `Table` sort comparator for a column. It's a plain value (not a key path) so the
/// chosen sort can be stored in user defaults as `"<column>.<asc|desc>"`.
nonisolated struct ColumnSort<Column: SortableColumn>: SortComparator, Sendable {
    var column: Column
    var order: SortOrder

    init(_ column: Column, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    func compare(_ lhs: Column.Row, _ rhs: Column.Row) -> ComparisonResult {
        switch (column.hasValue(lhs), column.hasValue(rhs)) {
        case (true, false): return .orderedAscending
        case (false, true): return .orderedDescending
        case (false, false): return Column.tiebreak(lhs, rhs)
        case (true, true):
            let result = column.ascending(lhs, rhs)
            if result == .orderedSame { return Column.tiebreak(lhs, rhs) }
            return order == .forward ? result : result.reversed
        }
    }

    var storageValue: String { "\(column.rawValue).\(order == .forward ? "asc" : "desc")" }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let column = Column(rawValue: parts[0]) else { return nil }
        switch parts[1] {
        case "asc": self.init(column, order: .forward)
        case "desc": self.init(column, order: .reverse)
        default: return nil
        }
    }
}

extension ComparisonResult {
    nonisolated var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}

nonisolated func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
}

// MARK: - Browse

nonisolated enum BrowseColumn: String, SortableColumn {
    case name, support, stars, updated

    func ascending(_ lhs: SearchResult, _ rhs: SearchResult) -> ComparisonResult {
        switch self {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .support: compareValues(Self.supportRank(lhs.support), Self.supportRank(rhs.support))
        case .stars: compareValues(lhs.stars ?? 0, rhs.stars ?? 0)
        case .updated: compareValues(lhs.lastUpdated ?? .distantPast, rhs.lastUpdated ?? .distantPast)
        }
    }

    func hasValue(_ row: SearchResult) -> Bool {
        switch self {
        case .name, .support: true
        case .stars: row.stars != nil
        case .updated: row.lastUpdated != nil
        }
    }

    static func tiebreak(_ lhs: SearchResult, _ rhs: SearchResult) -> ComparisonResult {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        return byName == .orderedSame ? lhs.id.identifier.localizedStandardCompare(rhs.id.identifier) : byName
    }

    /// Ascending puts confirmed Forever support first.
    static func supportRank(_ status: SupportStatus) -> Int {
        switch status {
        case .supported: 0
        case .checking: 1
        case .needsDownload: 2
        case .unknown: 3
        case .unsupported: 4
        case .noReleases: 5
        }
    }
}

// MARK: - Installed

/// One row of the Installed table: an add-on plus what the table shows and sorts by.
nonisolated struct InstalledRow: Identifiable, Hashable, Sendable {
    /// Ascending puts what needs attention first.
    enum Condition: Int, Comparable, Sendable {
        case missingFolders, updateAvailable, failed, noCompatibleRelease, pinned, upToDate, unchecked, unmanaged

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var status: AddonStatus
    var name: String
    /// Repository for managed add-ons, TOC title for unmanaged folders.
    var subtitle: String?
    var version: String
    var availableVersion: String?
    var channel: Channel?
    var installedAt: Date?
    var condition: Condition
    var failure: String?

    var id: AddonStatus.ID { status.id }

    init(status: AddonStatus, update: UpdateState?) {
        self.status = status
        switch status {
        case .managed(let addon, let missing):
            name = addon.name
            subtitle = addon.id.identifier
            version = addon.version
            channel = addon.channel
            installedAt = addon.installedAt
            if case .available(let release) = update, !addon.pinned { availableVersion = release.version }
            if !missing.isEmpty {
                condition = .missingFolders
            } else if addon.pinned {
                condition = .pinned
            } else {
                switch update {
                case .available: condition = .updateAvailable
                case .failed(let message): condition = .failed; failure = message
                case .noCompatibleRelease: condition = .noCompatibleRelease
                case .pinned: condition = .pinned
                case .upToDate: condition = .upToDate
                case nil: condition = .unchecked
                }
            }
        case .unmanaged(let folder, let toc, _):
            name = folder
            subtitle = toc?.title.flatMap { $0 == folder ? nil : $0 }
            version = toc?.version ?? ""
            condition = .unmanaged
        }
    }

    var addon: InstalledAddon? {
        if case .managed(let addon, _) = status { addon } else { nil }
    }

    var missingFolders: [String] {
        if case .managed(_, let missing) = status { missing } else { [] }
    }
}

nonisolated enum InstalledColumn: String, SortableColumn {
    case name, version, channel, status, installed

    func ascending(_ lhs: InstalledRow, _ rhs: InstalledRow) -> ComparisonResult {
        switch self {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        // `localizedStandardCompare` orders numbers numerically, so 1.10 sorts after 1.9.
        case .version: lhs.version.localizedStandardCompare(rhs.version)
        case .channel: compareValues(lhs.channel?.rawValue ?? "", rhs.channel?.rawValue ?? "")
        case .status: compareValues(lhs.condition, rhs.condition)
        case .installed: compareValues(lhs.installedAt ?? .distantPast, rhs.installedAt ?? .distantPast)
        }
    }

    func hasValue(_ row: InstalledRow) -> Bool {
        switch self {
        case .name, .status: true
        case .version: !row.version.isEmpty
        case .channel: row.channel != nil
        case .installed: row.installedAt != nil
        }
    }

    static func tiebreak(_ lhs: InstalledRow, _ rhs: InstalledRow) -> ComparisonResult {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        return byName == .orderedSame ? lhs.id.compare(rhs.id) : byName
    }
}
