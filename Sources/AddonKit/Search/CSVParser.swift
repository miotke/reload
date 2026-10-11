import Foundation

/// RFC 4180 CSV reader: quoted fields, `""` escapes, embedded commas and newlines,
/// CRLF or LF line endings. Lenient: stray quotes inside unquoted fields are kept
/// literally, and text after a closing quote is appended to the field.
public enum CSVParser {
    public static func parse(_ text: String) -> [[String]] {
        parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) -> [[String]] {
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var fieldStarted = false   // any byte (or quote) seen for the current field
        var recordStarted = false

        func endField() {
            record.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            fieldStarted = false
        }
        func endRecord() {
            endField()
            // A blank line yields a single empty field; drop it.
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record.removeAll(keepingCapacity: true)
            recordStarted = false
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var bytes = raw.bindMemory(to: UInt8.self)[...]
            // UTF-8 BOM
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
            var i = bytes.startIndex
            let end = bytes.endIndex
            while i < end {
                let byte = bytes[i]
                if inQuotes {
                    if byte == quote {
                        let next = bytes.index(after: i)
                        if next < end, bytes[next] == quote {
                            field.append(quote)
                            i = bytes.index(after: next)
                            continue
                        }
                        inQuotes = false
                    } else {
                        field.append(byte)
                    }
                    i = bytes.index(after: i)
                    continue
                }
                switch byte {
                case quote where !fieldStarted:
                    inQuotes = true
                    fieldStarted = true
                    recordStarted = true
                case comma:
                    endField()
                    recordStarted = true
                case cr:
                    let next = bytes.index(after: i)
                    if next < end, bytes[next] == lf { i = next }
                    endRecord()
                case lf:
                    endRecord()
                default:
                    field.append(byte)
                    fieldStarted = true
                    recordStarted = true
                }
                i = bytes.index(after: i)
            }
        }
        if recordStarted || !field.isEmpty { endRecord() }
        return records
    }
}

/// Maps `github-wow-addon-catalogue/addons.csv` rows to `CatalogueEntry`.
public enum CatalogueCSV {
    public static let columns = [
        "id", "name", "full_name", "url", "description", "last_updated", "flavors",
        "curse_id", "wago_id", "wowi_id", "has_release_json", "last_seen",
    ]

    /// Parses the whole file. Rows with the wrong field count or missing required
    /// values are skipped. Returns an empty array if the header lacks required columns.
    public static func entries(from data: Data) -> [CatalogueEntry] {
        let records = CSVParser.parse(data)
        guard let header = records.first else { return [] }
        var column: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            column[name.trimmingCharacters(in: .whitespaces).lowercased()] = index
        }
        guard let idCol = column["id"], let nameCol = column["name"],
              let fullNameCol = column["full_name"], let urlCol = column["url"] else { return [] }

        var entries: [CatalogueEntry] = []
        entries.reserveCapacity(records.count)
        for row in records.dropFirst() {
            guard row.count == header.count else { continue }
            func value(_ key: String) -> String? {
                guard let index = column[key] else { return nil }
                let v = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            guard let id = nonEmpty(row[idCol]),
                  let name = nonEmpty(row[nameCol]),
                  let fullName = nonEmpty(row[fullNameCol]),
                  fullName.split(separator: "/").count == 2,
                  let urlString = nonEmpty(row[urlCol]),
                  let url = URL(string: urlString), url.scheme != nil
            else { continue }

            entries.append(CatalogueEntry(
                id: id,
                name: name,
                fullName: fullName,
                url: url,
                description: value("description"),
                lastUpdated: value("last_updated").flatMap(parseDate),
                flavors: (value("flavors") ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                curseID: value("curse_id").flatMap { Int($0) },
                wagoID: value("wago_id"),
                wowiID: value("wowi_id").flatMap { Int($0) },
                hasReleaseJSON: value("has_release_json")?.lowercased() == "true"
            ))
        }
        return entries
    }

    /// ISO-8601 with or without fractional seconds, `Z` or `±hh:mm` offsets.
    public static func parseDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        // Fallback: trim fractional seconds to 3 digits (some parsers reject microseconds).
        if let dot = string.firstIndex(of: "."), dot < string.endIndex {
            let afterDot = string[string.index(after: dot)...]
            let digits = afterDot.prefix(while: \.isNumber)
            let rest = afterDot.dropFirst(digits.count)
            let trimmed = string[..<dot] + "." + digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
            return try? Date(String(trimmed), strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        return nil
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
