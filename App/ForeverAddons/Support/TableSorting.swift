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

