import AddonKit
import Foundation

/// `--json` output: one document per command with a top-level `"schemaVersion": 1`
/// and ISO-8601 dates (docs/cli/commands.md).
enum JSONOutput {
    static let schemaVersion = 1

    static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The JSON document for `payload`: its fields plus `schemaVersion`.
    static func document<Payload: Encodable>(_ payload: Payload) throws -> String {
        let data = try encoder().encode(Document(payload: payload))
        return String(decoding: data, as: UTF8.self)
    }

    /// `{"error": {"code": …, "message": …}}`
    static func error(_ error: any Error) -> String {
        let body = ErrorDocument(error: .init(code: ExitStatus.identifier(for: error), message: ExitStatus.message(for: error)))
        let data = (try? encoder(pretty: false).encode(body)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private struct Document<Payload: Encodable>: Encodable {
        var payload: Payload
        enum CodingKeys: String, CodingKey { case schemaVersion }
        func encode(to encoder: any Encoder) throws {
            try payload.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(JSONOutput.schemaVersion, forKey: .schemaVersion)
        }
    }

    struct ErrorDocument: Encodable {
        struct Body: Encodable {
            var code: String
            var message: String
        }
        var error: Body
    }
}

// MARK: - Encodable wrappers for model types that aren't Codable

struct ReleaseJSON: Encodable, Equatable {
    var ref: AddonRef
    var name: String
    var version: String
    var releaseID: Int64
    var publishedAt: Date
    var downloadURL: URL
    var assetName: String
    var changelog: String?
    var isPrerelease: Bool
    var reasoning: [String]

    init(_ release: ResolvedRelease, includeChangelog: Bool = true) {
        ref = release.ref
        name = release.name
        version = release.version
        releaseID = release.releaseID
        publishedAt = release.publishedAt
        downloadURL = release.downloadURL
        assetName = release.assetName
        changelog = includeChangelog ? release.changelog : nil
        isPrerelease = release.isPrerelease
        reasoning = release.reasoning
    }
}

struct SupportJSON: Encodable, Equatable {
    /// `supported`, `unsupported`, `noReleases`, `needsDownload`, `checking`, `unknown`.
    var status: String
    var version: String?

    init(_ support: SupportStatus) {
        switch support {
        case .supported(let version): status = "supported"; self.version = version
        case .unsupported: status = "unsupported"
        case .noReleases: status = "noReleases"
        case .needsDownload: status = "needsDownload"
        case .checking: status = "checking"
        case .unknown: status = "unknown"
        }
    }
}

struct UpdateStateJSON: Encodable, Equatable {
    /// `upToDate`, `available`, `pinned`, `noCompatibleRelease`, `failed`.
    var state: String
    /// The version an `available` update would install.
    var version: String?
    var release: ReleaseJSON?
    var message: String?

    init(_ updateState: UpdateState) {
        switch updateState {
        case .upToDate: state = "upToDate"
        case .available(let release):
            state = "available"
            version = release.version
            self.release = ReleaseJSON(release, includeChangelog: false)
        case .pinned: state = "pinned"
        case .noCompatibleRelease: state = "noCompatibleRelease"
        case .failed(let message): state = "failed"; self.message = message
        }
    }

    /// A state known only by version, e.g. from stored details rather than a resolved release.
    init(state: String, version: String? = nil, message: String? = nil) {
        self.state = state
        self.version = version
        self.message = message
    }
}

struct SearchResultJSON: Encodable {
    var id: AddonRef
    var name: String
    var summary: String?
    var owner: String
    var stars: Int?
    var lastUpdated: Date?
    var installed: InstalledAddon?
    var support: SupportJSON
    /// Every flavor the latest release ships; absent when not checked.
    var availableFlavors: [Flavor]?
    var families: [GameFamily]?
    var origin: [SearchOrigin]

    init(_ result: SearchResult) {
        availableFlavors = GamesJSON.flavors(result.availableFlavors)
        families = GamesJSON.families(result.availableFlavors)
        id = result.id
        name = result.name
        summary = result.summary
        owner = result.owner
        stars = result.stars
        lastUpdated = result.lastUpdated
        installed = result.installed
        support = SupportJSON(result.support)
        origin = result.origin.sorted { $0.rawValue < $1.rawValue }
    }
}

/// `availableFlavors` and `families` as sorted arrays, absent when not checked.
enum GamesJSON {
    static func flavors(_ flavors: Set<Flavor>?) -> [Flavor]? {
        flavors.map { set in Flavor.allCases.filter(set.contains) }
    }

    static func families(_ flavors: Set<Flavor>?) -> [GameFamily]? {
        flavors.map { $0.families.sorted() }
    }
}

struct AddonStatusJSON: Encodable {
    /// `managed` or `unmanaged`.
    var kind: String
    /// From the latest release's release.json, or the TOCs on disk; absent when not known.
    var availableFlavors: [Flavor]?
    var families: [GameFamily]?
    var addon: InstalledAddon?
    var missingFolders: [String]?
    var folder: String?
    var title: String?
    var tocVersion: String?
    var suggestedRef: AddonRef?
    /// Every folder in an unmanaged group, `folder` first.
    var folders: [String]?
    /// The TOC the client loads for the installation's flavor, e.g. `Questie_Camelot.toc`.
    var tocFile: String?
    var supportsFlavor: Bool?
    var candidates: [CandidateJSON]?
    /// Folders a managed add-on's loaded TOC requires that aren't installed.
    var missingDependencies: [String]?

    struct CandidateJSON: Encodable, Equatable {
        var ref: AddonRef
        var name: String
        var reason: String
        var confidence: String
    }

    init(_ status: AddonStatus, availableFlavors: Set<Flavor>? = nil, missingDependencies: [String]? = nil) {
        self.availableFlavors = GamesJSON.flavors(availableFlavors)
        families = GamesJSON.families(availableFlavors)
        switch status {
        case .managed(let addon, let missing):
            kind = "managed"
            self.addon = addon
            missingFolders = missing
            self.missingDependencies = missingDependencies ?? []
        case .unmanaged(let unmanaged):
            kind = "unmanaged"
            folder = unmanaged.folder
            folders = unmanaged.folders
            title = unmanaged.toc?.displayTitle
            tocVersion = unmanaged.version
            tocFile = unmanaged.tocFile
            supportsFlavor = unmanaged.supportsFlavor
            suggestedRef = unmanaged.suggestedRef
            candidates = unmanaged.candidates.map { CandidateJSON(ref: $0.ref, name: $0.name, reason: $0.reason, confidence: $0.confidence.label) }
        }
    }
}
