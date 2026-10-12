import Foundation

/// Which game an add-on build is for, at the level players care about: Retail, Forever, or
/// any of the classic re-releases (docs/architecture/flavors.md#game-families). Forever runs
/// on the modern UI, so a Retail build often loads there, listed as out of date.
public enum GameFamily: String, Codable, Sendable, CaseIterable, Comparable {
    case retail
    case forever
    case classic

    /// One letter for the R / F / C bubbles and the CLI's GAMES column.
    public var letter: String {
        switch self {
        case .retail: "R"
        case .forever: "F"
        case .classic: "C"
        }
    }

    public var displayName: String {
        switch self {
        case .retail: "Retail"
        case .forever: "Forever"
        case .classic: "Classic"
        }
    }

    /// The flavors in this family, in `Flavor.allCases` order.
    public var flavors: [Flavor] { Flavor.allCases.filter { $0.family == self } }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

extension Flavor {
    public var family: GameFamily {
        switch self {
        case .mainline: .retail
        case .forever: .forever
        case .vanilla, .tbc, .wrath, .titan, .cata, .mists: .classic
        }
    }

    /// The name inside its family, for tooltips like "Classic: Era, Wrath, Mists".
    public var shortName: String {
        switch self {
        case .mainline: "Retail"
        case .forever: "Forever"
        case .vanilla: "Era"
        case .tbc: "TBC Anniversary"
        case .wrath: "Wrath"
        case .titan: "Titan"
        case .cata: "Cata"
        case .mists: "Mists"
        }
    }

    /// The build an installation may fall back to, only with the user's explicit consent,
    /// when an add-on has none for this flavor: Forever loads the Retail (`_Mainline`) TOC.
    public var fallbackFlavor: Flavor? {
        self == .forever ? .mainline : nil
    }

    /// The flavor a BigWigs packager `release.json` name (`mainline`, `bcc`, `camelot`…) means.
    public static func from(releaseJSONName name: String) -> Flavor? {
        let lowered = name.lowercased()
        return allCases.first { $0.rules.releaseJSONFlavors.contains(lowered) }
    }

    /// Whether "hide incompatible" hides a result with these families on this installation
    /// (docs/features/search.md#hide-incompatible):
    /// - Forever hides classic-only add-ons; Retail-only ones stay, since they often load.
    /// - Retail hides add-ons without a Retail build; the classics, those without a Classic one.
    /// - Unknown families (`nil`, not checked) are kept; a repo with no releases is hidden.
    public func hidesAsIncompatible(families: Set<GameFamily>?, support: SupportStatus) -> Bool {
        if case .noReleases = support { return true }
        guard let families else { return false }
        switch family {
        case .forever: return families.isEmpty || families == [.classic]
        case .retail, .classic: return !families.contains(family)
        }
    }
}

extension Set<Flavor> {
    /// The game families these flavors belong to.
    public var families: Set<GameFamily> { Set<GameFamily>(map(\.family)) }

    /// Raw values in `Flavor.allCases` order, comma-separated: the stored form.
    var storageValue: String {
        Flavor.allCases.filter(contains).map(\.rawValue).joined(separator: ",")
    }

    /// Parses `storageValue`, ignoring names this version doesn't know.
    init(storageValue: String) {
        self.init(storageValue.split(separator: ",").compactMap { Flavor(rawValue: String($0)) })
    }
}

/// One sentence on what an add-on's builds mean for an installation, shared by the app's
/// inspector and `reload info` (docs/architecture/flavors.md#game-families).
public enum GameAvailability {
    public static func sentence(availableFlavors: Set<Flavor>?, for flavor: Flavor) -> String {
        guard let available = availableFlavors else { return "Not checked yet" }
        let families = available.families
        if flavor == .forever {
            if available.contains(.forever) { return "Has a Forever build" }
            if families.contains(.retail) { return "Retail build only: may work on Forever; it will show as out of date" }
            if families == [.classic] { return "Classic only: won't load on Forever" }
            return "No Forever build"
        }
        if available.contains(flavor) { return "Has a \(flavor.displayName) build" }
        if families.contains(flavor.family) {
            return "Has \(flavor.family.displayName) builds, but none for \(flavor.displayName)"
        }
        return "No \(flavor.displayName) build"
    }
}
