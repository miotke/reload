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
}

public enum SourceID: String, Codable, Sendable, CaseIterable {
    case github
    case wowinterface
    case tukui
}

public struct AddonRef: Codable, Hashable, Sendable, CustomStringConvertible {
    public var source: SourceID
    /// `owner/repo` for GitHub.
    public var identifier: String

    public init(source: SourceID, identifier: String) {
        self.source = source
        self.identifier = identifier
    }

    public var description: String { "\(source.rawValue):\(identifier)" }
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
    /// Update checks compare this plus `publishedAt` (DESIGN.md §5).
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

    public init(
        id: AddonRef, name: String, folders: [String], version: String, releaseID: Int64,
        assetName: String, publishedAt: Date, installedAt: Date, channel: Channel = .stable,
        pinned: Bool = false, etag: String? = nil, changelog: String? = nil,
        previousRelease: ReleaseSnapshot? = nil
    ) {
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
        ReleaseSnapshot(version: version, releaseID: releaseID, assetName: assetName, publishedAt: publishedAt, changelog: changelog)
    }

    /// True when `release` should replace this install.
    public func isUpdate(_ release: ResolvedRelease) -> Bool {
        release.releaseID != releaseID && release.publishedAt > publishedAt
    }
}

/// Enough of a past release to reinstall it from the download cache.
public struct ReleaseSnapshot: Codable, Sendable, Hashable {
    public var version: String
    public var releaseID: Int64
    public var assetName: String
    public var publishedAt: Date
    public var changelog: String?

    public init(version: String, releaseID: Int64, assetName: String, publishedAt: Date, changelog: String? = nil) {
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
    /// Human-readable trail of how this release/asset was chosen (`addonctl resolve`).
    public var reasoning: [String]

    public init(
        ref: AddonRef, name: String, version: String, releaseID: Int64, publishedAt: Date,
        downloadURL: URL, assetName: String, changelog: String? = nil, isPrerelease: Bool = false,
        reasoning: [String] = []
    ) {
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
    /// A folder in `AddOns/` that no managed add-on owns.
    case unmanaged(folder: String, toc: Toc?, suggestedRef: AddonRef?)

    public var id: String {
        switch self {
        case .managed(let addon, _): addon.id.description
        case .unmanaged(let folder, _, _): "unmanaged:\(folder)"
        }
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

/// The Browse tab with an empty query (DESIGN.md §7.5).
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
