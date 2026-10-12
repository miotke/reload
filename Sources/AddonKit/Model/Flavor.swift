import Foundation

/// A WoW client: one game with its own add-on builds. Forever is the one this app is
/// built for, but every flavor works end to end so adding a game is a `rules` entry.
public enum Flavor: String, Codable, Sendable, CaseIterable {
    case mainline
    case forever
    case vanilla
    case tbc
    case wrath
    case titan
    case cata
    case mists
}

/// Every flavor-specific constant lives here (docs/architecture/flavors.md).
public struct FlavorRules: Sendable {
    /// Valid `## Interface:` values. No two flavors' ranges overlap.
    ///
    /// Interface numbers and game versions encode the same way (`major * 10000 + minor * 100
    /// + patch`: `11508` is 1.15.8, `16001` is 1.60.1), so these ranges also bound game versions.
    public var interfaceRanges: [ClosedRange<Int>]
    /// TOC suffixes unique to this flavor, matched after `_` or `-`.
    public var tocSuffixes: [String]
    /// TOC suffixes shared with other flavors, in the order the client tries them; valid only
    /// if the TOC's interface is in range (`_Mainline` for Forever, `_Classic` for the classics).
    public var sharedTocSuffixes: [String]
    /// `flavor` values used in BigWigs packager `release.json` files.
    public var releaseJSONFlavors: [String]
    /// Known `World of Warcraft/<subfolder>` names mapped to Battle.net product codes. The
    /// folder only seeds the product; `.build.info`'s version decides the flavor.
    public var knownSubfolders: [String: String]

    /// Game versions encoded like `Flavor.encodeGameVersion`; the same numbers as `interfaceRanges`.
    public var gameVersionRanges: [ClosedRange<Int>] { interfaceRanges }

    public func contains(interface: Int) -> Bool {
        interfaceRanges.contains { $0.contains(interface) }
    }
}

extension Flavor {
    public var rules: FlavorRules {
        switch self {
        case .mainline:
            FlavorRules(
                // Original releases before each classic re-release, then everything from 6.0 on.
                interfaceRanges: [
                    1_00_00...1_12_99, 2_00_00...2_04_99, 3_00_00...3_03_99,
                    4_00_00...4_03_99, 5_00_00...5_04_99, 6_00_00...99_99_99,
                ],
                tocSuffixes: ["Mainline"],
                sharedTocSuffixes: [],
                releaseJSONFlavors: ["mainline", "retail"],
                knownSubfolders: ["_retail_": "wow", "_ptr_": "wowt", "_beta_": "wow_beta"]
            )
        case .forever:
            FlavorRules(
                interfaceRanges: [1_60_00...1_99_99],
                tocSuffixes: ["Camelot", "Forever"],
                sharedTocSuffixes: ["Mainline"],
                releaseJSONFlavors: ["forever", "camelot"],
                knownSubfolders: ["_classic_beta_": "wow_classic_beta"]
            )
        case .vanilla:
            FlavorRules(
                interfaceRanges: [1_13_00...1_59_99],
                tocSuffixes: ["Vanilla"],
                sharedTocSuffixes: ["Classic"],
                releaseJSONFlavors: ["classic", "vanilla"],
                knownSubfolders: ["_classic_era_": "wow_classic_era"]
            )
        case .tbc:
            FlavorRules(
                interfaceRanges: [2_05_00...2_99_99],
                tocSuffixes: ["TBC", "BCC"],
                sharedTocSuffixes: ["Classic"],
                releaseJSONFlavors: ["bcc", "tbc"],
                knownSubfolders: ["_anniversary_": "wow_anniversary"]
            )
        case .wrath:
            FlavorRules(
                interfaceRanges: [3_04_00...3_79_99],
                tocSuffixes: ["Wrath", "WOTLKC"],
                sharedTocSuffixes: ["Classic"],
                releaseJSONFlavors: ["wrath"],
                knownSubfolders: [:]
            )
        case .titan:
            FlavorRules(
                // Titan loads Wrath TOCs, but those usually target Wrath Classic, so they
                // count only when their interface is a Titan one.
                interfaceRanges: [3_80_00...3_99_99],
                tocSuffixes: [],
                sharedTocSuffixes: ["Wrath", "WOTLKC", "Classic"],
                releaseJSONFlavors: ["titan"],
                knownSubfolders: [:]
            )
        case .cata:
            FlavorRules(
                interfaceRanges: [4_04_00...4_99_99],
                tocSuffixes: ["Cata"],
                sharedTocSuffixes: ["Classic"],
                releaseJSONFlavors: ["cata"],
                knownSubfolders: [:]
            )
        case .mists:
            FlavorRules(
                interfaceRanges: [5_05_00...5_99_99],
                tocSuffixes: ["Mists"],
                sharedTocSuffixes: ["Classic"],
                releaseJSONFlavors: ["mists"],
                // `_classic_` follows whichever classic is current; `.build.info` has the final say.
                knownSubfolders: ["_classic_": "wow_classic"]
            )
        }
    }

    /// Short name for the UI and CLI, e.g. "Mists Classic".
    public var displayName: String {
        switch self {
        case .mainline: "Retail"
        case .forever: "Forever"
        case .vanilla: "Classic Era"
        case .tbc: "TBC Anniversary"
        case .wrath: "Wrath Classic"
        case .titan: "Titan"
        case .cata: "Cata Classic"
        case .mists: "Mists Classic"
        }
    }

    /// The flavor whose game versions contain a version string like `"1.60.1.70338"`.
    public static func from(gameVersion: String) -> Flavor? {
        encodeGameVersion(gameVersion).flatMap(from(interface:))
    }

    /// The flavor whose `interfaceRanges` contain `interface`.
    public static func from(interface: Int) -> Flavor? {
        allCases.first { $0.rules.contains(interface: interface) }
    }

    /// The flavor a known Battle.net product code (`wow_classic_era`) maps to.
    public static func from(productCode: String) -> Flavor? {
        allCases.first { $0.rules.knownSubfolders.values.contains(productCode) }
    }

    /// The flavor a known `World of Warcraft/<subfolder>` name maps to, case-insensitively.
    public static func from(subfolder: String) -> Flavor? {
        allCases.first { $0.rules.knownSubfolders.keys.contains { $0.caseInsensitiveCompare(subfolder) == .orderedSame } }
    }

    /// `"1.60.1.70338"` → `16001`. Build numbers past the third component are ignored.
    public static func encodeGameVersion(_ version: String) -> Int? {
        let parts = version.split(separator: ".").prefix(3).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 } + Array(repeating: 0, count: 3 - parts.count)
        return numbers[0] * 1_00_00 + numbers[1] * 1_00 + numbers[2]
    }
}
