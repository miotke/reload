import Foundation

public struct Installation: Codable, Sendable, Identifiable, Hashable {
    /// Stable hash of the resolved root path.
    public var id: String
    /// e.g. `…/World of Warcraft/_classic_beta_`
    public var root: URL
    public var flavor: Flavor
    /// e.g. `wow_classic_beta`, from `.build.info`.
    public var productCode: String?
    /// e.g. `1.60.1.70338`
    public var gameVersion: String?

    public init(id: String, root: URL, flavor: Flavor, productCode: String? = nil, gameVersion: String? = nil) {
        self.id = id
        self.root = root
        self.flavor = flavor
        self.productCode = productCode
        self.gameVersion = gameVersion
    }

    public var addonsDirectory: URL { root.appending(path: "Interface/AddOns", directoryHint: .isDirectory) }

    private enum CodingKeys: String, CodingKey {
        case id, root, flavor, productCode, gameVersion
    }

    /// Stores written before the classics were split say `"classic"`; those are re-derived
    /// from the stored game version or product code instead of failing to load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        root = try container.decode(URL.self, forKey: .root)
        productCode = try container.decodeIfPresent(String.self, forKey: .productCode)
        gameVersion = try container.decodeIfPresent(String.self, forKey: .gameVersion)
        let raw = try container.decode(String.self, forKey: .flavor)
        guard let flavor = Flavor(rawValue: raw)
            ?? gameVersion.flatMap(Flavor.from(gameVersion:))
            ?? productCode.flatMap(Flavor.from(productCode:))
            ?? Flavor.from(subfolder: root.lastPathComponent) else {
            throw DecodingError.dataCorruptedError(forKey: .flavor, in: container, debugDescription: "unknown flavor \(raw)")
        }
        self.flavor = flavor
    }
}

/// Where an add-on comes from (docs/features/sources.md).
public enum SourceID: String, Codable, Sendable, CaseIterable {
    case github
    case wowinterface
    case tukui

    public var displayName: String {
        switch self {
        case .github: "GitHub"
        case .wowinterface: "WoWInterface"
        case .tukui: "Tukui"
        }
    }
}

public struct AddonRef: Codable, Hashable, Sendable, CustomStringConvertible {
    public var source: SourceID
    /// `owner/repo` for GitHub, the file ID for WoWInterface (`3826`), the slug for Tukui (`elvui`).
    public var identifier: String

    public init(source: SourceID, identifier: String) {
        self.source = source
        self.identifier = identifier
    }

    public var description: String { "\(source.rawValue):\(identifier)" }

    /// `owner/repo` for GitHub, `wowinterface:3826` for the others: the key the metadata
    /// database stores the ref under, and the short form messages and tables show. GitHub
    /// names can't contain a colon, so the two forms never collide.
    public var key: String { source == .github ? identifier : description }

    /// Reverses `key`.
    public init(key: String) {
        if let colon = key.firstIndex(of: ":"), let source = SourceID(rawValue: String(key[..<colon])), source != .github {
            self.init(source: source, identifier: String(key[key.index(after: colon)...]))
        } else {
            self.init(source: .github, identifier: key)
        }
    }
}

public enum Channel: String, Codable, Sendable, CaseIterable {
    case stable
    case prerelease
}

public struct InstalledAddon: Codable, Sendable, Identifiable, Hashable {
    public var id: AddonRef
    public var name: String
    /// Top-level folders this package owns in `AddOns/`.
    public var folders: [String]
    /// Tag name, for display only. Never compared.
    public var version: String
    /// Update checks compare this plus `publishedAt` (docs/architecture/core.md).
    public var releaseID: Int64
    public var assetName: String
    public var publishedAt: Date
    public var installedAt: Date
    public var channel: Channel
    /// Never auto-update.
    public var pinned: Bool
    /// Last ETag from the source's releases endpoint, stored only while up to date.
    public var etag: String?
    /// Release notes of the installed release (Markdown).
    public var changelog: String?
    /// The release installed before this one, for rollback.
    public var previousRelease: ReleaseSnapshot?
    /// Set when the installed build is another game's, chosen with `allowFamilyFallback`:
    /// `.mainline` for a Retail build on Forever. Update checks keep to that build until one
    /// for the installation's own flavor appears, which is then offered as the update. Nil
    /// for the installation's own build.
    public var installedFlavorBuild: Flavor?

    public init(
        id: AddonRef, name: String, folders: [String], version: String, releaseID: Int64,
        assetName: String, publishedAt: Date, installedAt: Date, channel: Channel = .stable,
        pinned: Bool = false, etag: String? = nil, changelog: String? = nil,
        previousRelease: ReleaseSnapshot? = nil, installedFlavorBuild: Flavor? = nil
    ) {
        self.installedFlavorBuild = installedFlavorBuild
        self.id = id
        self.name = name
        self.folders = folders
        self.version = version
        self.releaseID = releaseID
        self.assetName = assetName
        self.publishedAt = publishedAt
        self.installedAt = installedAt
        self.channel = channel
        self.pinned = pinned
        self.etag = etag
        self.changelog = changelog
        self.previousRelease = previousRelease
    }

    /// The installed release, for `previousRelease` of the next install.
    public var snapshot: ReleaseSnapshot {
        ReleaseSnapshot(
            version: version, releaseID: releaseID, assetName: assetName, publishedAt: publishedAt,
            changelog: changelog, flavorBuild: installedFlavorBuild)
    }

    /// True when `release` should replace this install.
    public func isUpdate(_ release: ResolvedRelease) -> Bool {
        // Switching builds (a Forever build replacing a Retail one) is an update even for the same tag.
        if release.flavorBuild != installedFlavorBuild { return true }
        // Releases resolved without the API carry a synthetic (negative) ID and no real
        // date, so only their tags can be compared.
        if release.releaseID < 0 || releaseID < 0 { return release.version != version }
        return release.releaseID != releaseID && release.publishedAt > publishedAt
    }
}

/// Enough of a past release to reinstall it from the download cache.
public struct ReleaseSnapshot: Codable, Sendable, Hashable {
    public var version: String
    public var releaseID: Int64
    public var assetName: String
    public var publishedAt: Date
    public var changelog: String?
    /// `InstalledAddon.installedFlavorBuild` of that release.
    public var flavorBuild: Flavor?

    public init(version: String, releaseID: Int64, assetName: String, publishedAt: Date, changelog: String? = nil, flavorBuild: Flavor? = nil) {
        self.flavorBuild = flavorBuild
        self.version = version
        self.releaseID = releaseID
        self.assetName = assetName
        self.publishedAt = publishedAt
        self.changelog = changelog
    }
}

public struct ResolvedRelease: Sendable, Hashable {
    public var ref: AddonRef
    public var name: String
    public var version: String
    public var releaseID: Int64
    public var publishedAt: Date
    public var downloadURL: URL
    public var assetName: String
    /// Release body, Markdown.
    public var changelog: String?
    public var isPrerelease: Bool
    /// Human-readable trail of how this release/asset was chosen (`reload resolve`).
    public var reasoning: [String]
    /// Another game's build, chosen with `allowFamilyFallback` (`.mainline` on Forever); nil
    /// for the installation's own flavor.
    public var flavorBuild: Flavor?

    public init(
        ref: AddonRef, name: String, version: String, releaseID: Int64, publishedAt: Date,
        downloadURL: URL, assetName: String, changelog: String? = nil, isPrerelease: Bool = false,
        reasoning: [String] = [], flavorBuild: Flavor? = nil
    ) {
        self.flavorBuild = flavorBuild
        self.ref = ref
        self.name = name
        self.version = version
        self.releaseID = releaseID
        self.publishedAt = publishedAt
        self.downloadURL = downloadURL
        self.assetName = assetName
        self.changelog = changelog
        self.isPrerelease = isPrerelease
        self.reasoning = reasoning
    }
}

public enum ResolveResult: Sendable {
    /// 304: nothing changed since `etag`.
    case notModified
    case release(ResolvedRelease, etag: String?)
}

/// Status of one managed or unmanaged add-on in an installation.
public enum AddonStatus: Sendable, Hashable, Identifiable {
    case managed(InstalledAddon, missingFolders: [String])
    /// A folder in `AddOns/` that no managed add-on owns, or a group of them one release covers.
    case unmanaged(UnmanagedFolder)

    public var id: String {
        switch self {
        case .managed(let addon, _): addon.id.description
        case .unmanaged(let folder): Self.unmanagedID(folder.folder)
        }
    }

    /// The row ID of the unmanaged entry named after `folder`.
    public static func unmanagedID(_ folder: String) -> String { "unmanaged:\(folder)" }

    public var unmanagedFolder: UnmanagedFolder? {
        if case .unmanaged(let folder) = self { folder } else { nil }
    }
}

public enum UpdateState: Sendable, Hashable {
    case upToDate
    case available(ResolvedRelease)
    case pinned
    case noCompatibleRelease
    case failed(String)
}

public enum OperationEvent: Sendable {
    case queued(AddonRef)
    case downloading(AddonRef, progress: Double)
    case installing(AddonRef)
    case done(InstalledAddon)
    /// Nothing to do, e.g. already up to date or pinned.
    case skipped(AddonRef, reason: String)
    case failed(AddonRef, String)
}

/// The Browse tab with an empty query (docs/features/search.md).
public struct BrowseContent: Sendable {
    public var popular: [SearchResult]
    public var recent: [SearchResult]
    public var categories: [SearchCategory]

    public init(popular: [SearchResult] = [], recent: [SearchResult] = [], categories: [SearchCategory] = []) {
        self.popular = popular
        self.recent = recent
        self.categories = categories
    }
}

/// Everything the inspector shows about an add-on, installed or not (docs/features/details-and-screenshots.md).
public struct AddonDetails: Sendable, Hashable {
    public var ref: AddonRef
    public var name: String
    public var owner: String
    public var summary: String?
    public var repositoryURL: URL
    public var homepage: URL?
    public var stars: Int?
    public var lastUpdated: Date?
    public var topics: [String]
    public var license: String?
    /// README as Markdown, if the repository has one.
    public var readme: String?
    /// Image URLs found in the README, absolute and de-duplicated, in document order.
    public var screenshots: [URL]
    /// Newest release that supports the requested flavor, if known.
    public var latestVersion: String?
    public var latestPublishedAt: Date?
    public var latestChangelog: String?
    public var support: SupportStatus
    /// Every flavor the latest release ships a build for; nil when not checked.
    public var availableFlavors: Set<Flavor>?
    public var fetchedAt: Date

    public var families: Set<GameFamily>? { availableFlavors?.families }

    public init(
        ref: AddonRef, name: String, owner: String, summary: String? = nil, repositoryURL: URL,
        homepage: URL? = nil, stars: Int? = nil, lastUpdated: Date? = nil, topics: [String] = [],
        license: String? = nil, readme: String? = nil, screenshots: [URL] = [], latestVersion: String? = nil,
        latestPublishedAt: Date? = nil, latestChangelog: String? = nil, support: SupportStatus = .unknown,
        availableFlavors: Set<Flavor>? = nil, fetchedAt: Date = .now
    ) {
        self.availableFlavors = availableFlavors
        self.ref = ref
        self.name = name
        self.owner = owner
        self.summary = summary
        self.repositoryURL = repositoryURL
        // Repo metadata is untrusted; only web links are kept.
        self.homepage = homepage.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        self.stars = stars
        self.lastUpdated = lastUpdated
        self.topics = topics
        self.license = license
        self.readme = readme
        self.screenshots = screenshots
        self.latestVersion = latestVersion
        self.latestPublishedAt = latestPublishedAt
        self.latestChangelog = latestChangelog
        self.support = support
        self.fetchedAt = fetchedAt
    }
}

/// Progress of `AddonManaging.refresh(in:force:)`.
public struct RefreshProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case catalogue      // downloading the add-on catalogue
        case updates        // checking installed add-ons for updates
        case support        // checking which add-ons support the flavor
        case finished
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int
    /// Short human-readable status, e.g. "Checking BigWigs…".
    public var message: String
    /// Set on `.finished`: the update states from this refresh.
    public var updates: [AddonRef: UpdateState]?

    public init(phase: Phase, completed: Int = 0, total: Int = 0, message: String = "", updates: [AddonRef: UpdateState]? = nil) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.message = message
        self.updates = updates
    }

    /// Overall progress in `0...1` across all phases.
    public var fraction: Double {
        let span: (Double, Double) = switch phase {
        case .catalogue: (0, 0.1)
        case .updates: (0.1, 0.3)
        case .support: (0.3, 1)
        case .finished: (1, 1)
        }
        let within = total > 0 ? Double(completed) / Double(total) : 0
        return span.0 + (span.1 - span.0) * min(max(within, 0), 1)
    }
}
