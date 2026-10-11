import Foundation

/// Blizzard's pipe-separated value format (BPSV), used by `World of Warcraft/.build.info`.
///
/// ```
/// Branch!STRING:0|Active!DEC:1|…|Version!STRING:0|Product!STRING:0
/// us|1|…|1.60.1.70338|wow_classic_beta
/// ```
public struct BuildInfo: Sendable, Hashable {
    /// One dictionary per data row, keyed by column name (type annotation stripped).
    public var rows: [[String: String]]

    public init(rows: [[String: String]]) {
        self.rows = rows
    }

    public init(parsing text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let header = lines.first else {
            self.rows = []
            return
        }
        let columns = header.split(separator: "|", omittingEmptySubsequences: false).map { column in
            String(column.split(separator: "!", maxSplits: 1).first ?? column)
        }
        self.rows = lines.dropFirst().map { line in
            let values = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            var row: [String: String] = [:]
            for (column, value) in zip(columns, values) { row[column] = value }
            return row
        }
    }

    public init(contentsOf url: URL) throws {
        self.init(parsing: try String(contentsOf: url, encoding: .utf8))
    }

    /// `Version` of the row whose `Product` is `product`.
    public func version(forProduct product: String) -> String? {
        rows.first { $0["Product"] == product }?["Version"]
    }
}
