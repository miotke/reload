import Foundation

/// A parsed `.toc` file header (docs/architecture/flavors.md). Only `## Key: Value` lines are read.
public struct Toc: Sendable, Hashable {
    /// Header fields keyed by lowercased name. Later duplicates win.
    public var fields: [String: String]

    public init(fields: [String: String]) {
        self.fields = fields
    }

    public init(parsing data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        self.init(parsing: text)
    }

    public init(parsing text: String) {
        var fields: [String: String] = [:]
        var body = Substring(text)
        if body.hasPrefix("\u{FEFF}") { body = body.dropFirst() }
        for rawLine in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("##") else { continue }
            let rest = line.dropFirst(2)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let key = rest[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key] = value
        }
        self.fields = fields
    }

    public subscript(key: String) -> String? {
        fields[key.lowercased()]
    }

    /// `## Interface: 120100, 16001` → `[120100, 16001]`.
    public var interfaces: [Int] {
        guard let raw = self["Interface"] else { return [] }
        return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Title with WoW colour codes (`|cffRRGGBB…|r`) and texture escapes removed.
    public var title: String? { self["Title"].map(Toc.stripEscapes) }
    public var version: String? { self["Version"] }
    public var notes: String? { self["Notes"].map(Toc.stripEscapes) }
    public var author: String? { self["Author"] }
    public var website: String? { self["X-Website"] }
    public var curseProjectID: String? { self["X-Curse-Project-ID"] }
    public var wowInterfaceID: String? { self["X-WoWI-ID"] }
    public var wagoID: String? { self["X-Wago-ID"] }

    public var requiredDependencies: [String] {
        Toc.list(self["Dependencies"] ?? self["RequiredDeps"] ?? self["Dep"])
    }

    public var optionalDependencies: [String] {
        Toc.list(self["OptionalDeps"])
    }

    /// True if any interface value belongs to `flavor`.
    public func supports(_ flavor: Flavor) -> Bool {
        interfaces.contains { flavor.rules.contains(interface: $0) }
    }

    static func list(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func stripEscapes(_ s: String) -> String {
        var out = s
        // |cAARRGGBB colour start, |r colour end, |T…|t textures, |A…|a atlases.
        for pattern in [#"\|c[0-9A-Fa-f]{8}"#, #"\|r"#, #"\|T[^|]*\|t"#, #"\|A[^|]*\|a"#] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// Splits TOC file names like `BigWigs_Camelot.toc` into add-on name and flavor suffix.
public struct TocFileName: Sendable, Hashable {
    public var addonName: String
    /// The suffix as written in the file name (e.g. `Camelot`), or nil for the base TOC.
    public var suffix: String?

    /// All suffixes recognised across every flavor.
    public static let knownSuffixes: [String] = Flavor.allCases
        .flatMap { $0.rules.tocSuffixes + $0.rules.sharedTocSuffixes }
        .reduce(into: []) { seen, suffix in if !seen.contains(suffix) { seen.append(suffix) } }

    public init(addonName: String, suffix: String?) {
        self.addonName = addonName
        self.suffix = suffix
    }

    /// Returns nil if `fileName` doesn't end in `.toc` (case-insensitive).
    public init?(_ fileName: String) {
        guard fileName.lowercased().hasSuffix(".toc") else { return nil }
        let stem = String(fileName.dropLast(4))
        for known in TocFileName.knownSuffixes {
            for sep in ["_", "-"] {
                let tail = sep + known
                if stem.count > tail.count, stem.lowercased().hasSuffix(tail.lowercased()) {
                    self.addonName = String(stem.dropLast(tail.count))
                    self.suffix = String(stem.suffix(known.count))
                    return
                }
            }
        }
        self.addonName = stem
        self.suffix = nil
    }

    /// True if this file name is specific to `flavor` (not shared, not base).
    public func isSpecific(to flavor: Flavor) -> Bool {
        guard let suffix else { return false }
        return flavor.rules.tocSuffixes.contains { $0.caseInsensitiveCompare(suffix) == .orderedSame }
    }

    /// True if this is a shared-family TOC for `flavor` (`_Mainline` for Forever, `_Classic` for the classics).
    public func isShared(for flavor: Flavor) -> Bool {
        sharedRank(for: flavor) != nil
    }

    /// Position of this file's suffix in `flavor`'s `sharedTocSuffixes`; lower is tried first.
    public func sharedRank(for flavor: Flavor) -> Int? {
        guard let suffix else { return nil }
        return flavor.rules.sharedTocSuffixes.firstIndex { $0.caseInsensitiveCompare(suffix) == .orderedSame }
    }
}
