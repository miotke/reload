import Foundation

/// A WoW client family. v1 only manages `.forever`; the others exist so the model
/// never assumes a single flavor.
public enum Flavor: String, Codable, Sendable, CaseIterable {
    case forever
    case mainline
    case classic
}

/// Every flavor-specific constant lives here (docs/design.md §6.1).
public struct FlavorRules: Sendable {
    /// Valid `## Interface:` values.
    public var interfaceRange: ClosedRange<Int>
    /// Game versions encoded as `major * 10000 + minor * 100 + patch`.
    public var gameVersionRange: ClosedRange<Int>
    /// TOC suffixes unique to this flavor, matched after `_` or `-`.
    public var tocSuffixes: [String]
    /// TOC suffixes shared with other flavors; valid only if the interface is in range.
    public var sharedTocSuffixes: [String]
    /// `flavor` values used in BigWigs packager `release.json` files.
    public var releaseJSONFlavors: [String]
    /// Known `World of Warcraft/<subfolder>` names mapped to Battle.net product codes.
    public var knownSubfolders: [String: String]
}

extension Flavor {
    public var rules: FlavorRules {
        switch self {
        case .forever:
            FlavorRules(
                interfaceRange: 16000...19999,
                gameVersionRange: 1_60_00...1_99_99,
                tocSuffixes: ["Camelot", "Forever"],
                sharedTocSuffixes: ["Mainline"],
                releaseJSONFlavors: ["forever"],
                knownSubfolders: ["_classic_beta_": "wow_classic_beta"]
            )
        case .mainline:
            FlavorRules(
                interfaceRange: 100000...199999,
                gameVersionRange: 10_00_00...19_99_99,
                tocSuffixes: ["Mainline"],
                sharedTocSuffixes: [],
                releaseJSONFlavors: ["mainline", "retail"],
                knownSubfolders: ["_retail_": "wow", "_ptr_": "wowt", "_beta_": "wow_beta"]
            )
        case .classic:
            FlavorRules(
                interfaceRange: 11300...59999,
                gameVersionRange: 1_13_00...5_99_99,
                tocSuffixes: ["Classic", "Vanilla", "TBC", "BCC", "Wrath", "WOTLKC", "Cata", "Mists"],
                sharedTocSuffixes: [],
                releaseJSONFlavors: ["classic", "bcc", "wrath", "cata", "mists", "titan"],
                knownSubfolders: ["_classic_": "wow_classic", "_classic_era_": "wow_classic_era", "_anniversary_": "wow_anniversary"]
            )
        }
    }

    /// The flavor whose `gameVersionRange` contains a version string like `"1.60.1.70338"`.
    public static func from(gameVersion: String) -> Flavor? {
        guard let encoded = encodeGameVersion(gameVersion) else { return nil }
        // Forever is checked first: its range sits inside classic's broad span.
        let ordered: [Flavor] = [.forever, .mainline, .classic]
        return ordered.first { $0.rules.gameVersionRange.contains(encoded) }
    }

    /// The flavor whose `interfaceRange` contains `interface`.
    public static func from(interface: Int) -> Flavor? {
        let ordered: [Flavor] = [.forever, .mainline, .classic]
        return ordered.first { $0.rules.interfaceRange.contains(interface) }
    }

    /// `"1.60.1.70338"` → `16001`. Build numbers past the third component are ignored.
    public static func encodeGameVersion(_ version: String) -> Int? {
        let parts = version.split(separator: ".").prefix(3).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 } + Array(repeating: 0, count: 3 - parts.count)
        return numbers[0] * 1_00_00 + numbers[1] * 1_00 + numbers[2]
    }
}
