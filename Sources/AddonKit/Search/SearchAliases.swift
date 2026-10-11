import Foundation

/// A Browse-tab category chip that runs a saved keyword search (DESIGN.md §7.5).
public struct SearchCategory: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// SF Symbol name for the chip.
    public var symbol: String
    /// Text passed to `SearchQuery.text` when the chip is tapped.
    public var query: String

    public init(id: String, title: String, symbol: String, query: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.query = query
    }
}

/// Static search vocabulary: query aliases and Browse categories.
public enum SearchAliases {
    /// Lower-case query word → the words it stands for. Expanded as an alternative,
    /// so `dbm` still matches `DBM-…` repos literally as well as `DeadlyBossMods`.
    public static let aliases: [String: [String]] = [
        "dbm": ["deadlybossmods"],
        "bw": ["bigwigs"],
        "lw": ["littlewigs"],
        "wa": ["weakauras"],
        "wa2": ["weakauras"],
        "tsm": ["tradeskillmaster"],
        "bt4": ["bartender4"],
        "rcl": ["rclootcouncil"],
        "mrt": ["methodraidtools"],
        "ert": ["exorsusraidtools"],
        "elv": ["elvui"],
        "bossmods": ["boss"],
    ]

    public static let categories: [SearchCategory] = [
        SearchCategory(id: "boss-mods", title: "Boss mods", symbol: "shield.lefthalf.filled", query: "boss"),
        SearchCategory(id: "bags", title: "Bags", symbol: "bag", query: "bag"),
        SearchCategory(id: "ui", title: "UI", symbol: "rectangle.3.group", query: "ui"),
        SearchCategory(id: "quests", title: "Quests", symbol: "list.bullet.rectangle", query: "quest"),
        SearchCategory(id: "maps", title: "Maps", symbol: "map", query: "map"),
        SearchCategory(id: "auction", title: "Auction", symbol: "dollarsign.circle", query: "auction"),
        SearchCategory(id: "combat", title: "Combat", symbol: "bolt", query: "combat"),
    ]
}
