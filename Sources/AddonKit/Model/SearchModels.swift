import Foundation

/// One row of the `catalogue` table: a repo from `github-wow-addon-catalogue/addons.csv` or a
/// live GitHub search, or an add-on from a WoWInterface or Tukui listing (docs/features/sources.md).
public struct CatalogueEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String          // catalogue `id`, or the host's own ID
    public var name: String
    /// `owner/repo` for GitHub, else `AddonRef.key` (`wowinterface:3826`).
    public var fullName: String
    public var url: URL
    public var description: String?
    public var lastUpdated: Date?
    public var flavors: [String]   // unreliable for Forever; informational only
    public var curseID: Int?
    public var wagoID: String?
    public var wowiID: Int?
    public var hasReleaseJSON: Bool
    /// Found by a live GitHub search rather than listed in the catalogue, so
    /// `hasReleaseJSON` says nothing about it.
    public var fromLiveSearch: Bool = false
    public var source: SourceID
    /// The listing's author, for hosted add-ons; GitHub rows use the repo owner.
    public var author: String?
    /// Images from a host's listing. GitHub rows have none: their README supplies them.
    public var screenshots: [URL]?
    /// Top-level folders a host's listing says the add-on ships (WoWInterface `UIDir`, Tukui
    /// `directories`). Stored in `catalogue.folders_json` for dependency lookups
    /// (docs/features/dependencies.md) and not read back into entries; nil for GitHub rows.
    public var folders: [String]?

    public init(
        id: String, name: String, fullName: String, url: URL, description: String? = nil,
        lastUpdated: Date? = nil, flavors: [String] = [], curseID: Int? = nil, wagoID: String? = nil,
        wowiID: Int? = nil, hasReleaseJSON: Bool = false, fromLiveSearch: Bool = false,
        source: SourceID = .github, author: String? = nil, screenshots: [URL] = [], folders: [String]? = nil
    ) {
        self.folders = folders
        self.source = source
        self.author = author
        self.screenshots = screenshots.isEmpty ? nil : screenshots
        self.fromLiveSearch = fromLiveSearch
        self.id = id
        self.name = name
        self.fullName = fullName
        self.url = url
        self.description = description
        self.lastUpdated = lastUpdated
        self.flavors = flavors
        self.curseID = curseID
        self.wagoID = wagoID
        self.wowiID = wowiID
        self.hasReleaseJSON = hasReleaseJSON
    }

    public var ref: AddonRef { source == .github ? AddonRef(source: .github, identifier: fullName) : AddonRef(key: fullName) }

    /// Game versions the host's listing claims, for hosted add-ons; nil for GitHub rows,
    /// whose catalogue `flavors` column under-reports Forever and isn't used.
    var listedFlavors: Set<Flavor>? {
        guard source != .github, !flavors.isEmpty else { return nil }
        return Set(flavors.compactMap(Flavor.init(rawValue:)))
    }
}

public struct SearchQuery: Sendable, Hashable {
    public var text: String
    public var flavor: Flavor
    /// Hides results whose builds can't run on the installation's family
    /// (`Flavor.hidesAsIncompatible`): classic-only ones on Forever, those without a Retail
    /// build on Retail, without a Classic build on the classics. Installed add-ons and direct
    /// refs always stay. It was `compatibleOnly`, and before that `foreverOnly`.
    public var hideIncompatible: Bool
    /// Keeps only results with a build for this family (`GameFamily.hides`), the app's games
    /// picker; nil keeps every game. Installed add-ons and direct refs always stay.
    public var games: GameFamily?
    public var includeLiveGitHub: Bool

    public init(text: String, flavor: Flavor, hideIncompatible: Bool = true, games: GameFamily? = nil, includeLiveGitHub: Bool = false) {
        self.text = text
        self.flavor = flavor
        self.hideIncompatible = hideIncompatible
        self.games = games
        self.includeLiveGitHub = includeLiveGitHub
    }
}

public enum SupportStatus: Sendable, Hashable {
    case unknown
    case checking
    case supported(version: String)
    case unsupported
    case noReleases
    /// Has releases but no release.json; confirming needs a zip download.
    case needsDownload
}

public enum SearchOrigin: String, Sendable, Hashable, Codable {
    case installed, catalogue, github, direct
}

public struct SearchResult: Sendable, Identifiable, Hashable {
    public var id: AddonRef
    public var name: String
    public var summary: String?
    public var owner: String
    public var stars: Int?
    public var lastUpdated: Date?
    public var installed: InstalledAddon?
    public var support: SupportStatus
    /// Every flavor the latest release ships a build for, as stored; nil when not checked.
    public var availableFlavors: Set<Flavor>?
    public var origin: Set<SearchOrigin>

    public var families: Set<GameFamily>? { availableFlavors?.families }

    public init(
        id: AddonRef, name: String, summary: String? = nil, owner: String, stars: Int? = nil,
        lastUpdated: Date? = nil, installed: InstalledAddon? = nil, support: SupportStatus = .unknown,
        availableFlavors: Set<Flavor>? = nil, origin: Set<SearchOrigin>
    ) {
        self.availableFlavors = availableFlavors
        self.id = id
        self.name = name
        self.summary = summary
        self.owner = owner
        self.stars = stars
        self.lastUpdated = lastUpdated
        self.installed = installed
        self.support = support
        self.origin = origin
    }
}

/// One emission of `searchUpdates`: the merged results plus what's still running.
public struct SearchUpdate: Sendable, Hashable {
    public var results: [SearchResult]
    /// True while a GitHub live search is in flight (show "Searching GitHub…").
    public var isSearchingGitHub: Bool
    /// True on the last emission.
    public var isComplete: Bool

    public init(results: [SearchResult], isSearchingGitHub: Bool = false, isComplete: Bool = false) {
        self.results = results
        self.isSearchingGitHub = isSearchingGitHub
        self.isComplete = isComplete
    }
}

public protocol SearchProvider: Sendable {
    func search(_ query: SearchQuery) async throws -> [SearchResult]
}

/// Checks whether an add-on supports a flavor without downloading it (docs/features/release-selection.md).
/// Implemented by `LatestReleaseStore`; implementations manage their own rate-limit budget
/// and return `.unknown` rather than spending the reserve kept for installs.
public protocol SupportChecking: Sendable {
    func support(for ref: AddonRef, flavor: Flavor) async -> SupportStatus
}
