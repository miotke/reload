import Foundation

/// One row of `github-wow-addon-catalogue/addons.csv`.
public struct CatalogueEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String          // catalogue `id`
    public var name: String
    public var fullName: String    // owner/repo
    public var url: URL
    public var description: String?
    public var lastUpdated: Date?
    public var flavors: [String]   // unreliable for Forever; informational only
    public var curseID: Int?
    public var wagoID: String?
    public var wowiID: Int?
    public var hasReleaseJSON: Bool

    public init(
        id: String, name: String, fullName: String, url: URL, description: String? = nil,
        lastUpdated: Date? = nil, flavors: [String] = [], curseID: Int? = nil, wagoID: String? = nil,
        wowiID: Int? = nil, hasReleaseJSON: Bool = false
    ) {
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

    public var ref: AddonRef { AddonRef(source: .github, identifier: fullName) }
}

public struct SearchQuery: Sendable, Hashable {
    public var text: String
    public var flavor: Flavor
    public var foreverOnly: Bool
    public var includeLiveGitHub: Bool

    public init(text: String, flavor: Flavor = .forever, foreverOnly: Bool = true, includeLiveGitHub: Bool = false) {
        self.text = text
        self.flavor = flavor
        self.foreverOnly = foreverOnly
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
    public var origin: Set<SearchOrigin>

    public init(
        id: AddonRef, name: String, summary: String? = nil, owner: String, stars: Int? = nil,
        lastUpdated: Date? = nil, installed: InstalledAddon? = nil, support: SupportStatus = .unknown,
        origin: Set<SearchOrigin>
    ) {
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

public protocol SearchProvider: Sendable {
    func search(_ query: SearchQuery) async throws -> [SearchResult]
}

/// Checks whether an add-on supports a flavor without downloading it (DESIGN.md §7.3).
/// Implemented by `GitHubSource`; implementations manage their own rate-limit budget
/// and return `.unknown` rather than spending the reserve kept for installs.
public protocol SupportChecking: Sendable {
    func support(for ref: AddonRef, flavor: Flavor) async -> SupportStatus
}
