import Foundation

/// A host that publishes one listing of all its add-ons and a single zip per add-on, with no
/// per-game builds: WoWInterface and Tukui (docs/features/sources.md). Implementations only
/// build URLs and parse; `HostedCatalogue` makes the requests and stores the answers.
///
/// Neither host says whether a file supports Forever, so the zip's TOCs decide
/// (`AddonManager.resolveHosted`), the same way as a GitHub release without a release.json.
protocol HostedSource: Sendable {
    var id: SourceID { get }
    /// Every add-on the host lists, in one keyless request.
    var listingURL: URL { get }
    /// Catalogue rows from the listing. `flavors` holds `Flavor` raw values for the game
    /// versions the author claims, which the listing never maps to Forever.
    func entries(fromListing data: Data) throws -> [CatalogueEntry]
    /// One request that answers the latest file of every identifier in `identifiers`.
    func filesURL(for identifiers: [String]) -> URL
    /// Latest files by identifier, from `filesURL`'s response.
    func files(from data: Data) throws -> [String: HostedFile]
    /// `wowinterface:3826`, a WoWInterface URL, `tukui:elvui`, … → a ref; nil if it isn't ours.
    func parse(_ input: String) -> AddonRef?
    /// The add-on's page on the host's website.
    func webURL(for identifier: String) -> URL?
}

/// The latest file a host offers for one add-on.
public struct HostedFile: Codable, Sendable, Hashable {
    public var identifier: String
    public var name: String
    public var author: String?
    public var version: String
    public var publishedAt: Date
    public var downloadURL: URL
    public var fileName: String
    /// Markdown.
    public var summary: String?
    /// Markdown.
    public var changelog: String?
    public var screenshots: [URL]
    /// The download's MD5 as the host published it (WoWInterface's `UIMD5`), if any.
    public var md5: String?

    public init(
        identifier: String, name: String, author: String? = nil, version: String, publishedAt: Date, downloadURL: URL,
        fileName: String, summary: String? = nil, changelog: String? = nil, screenshots: [URL] = [], md5: String? = nil
    ) {
        self.md5 = md5
        self.identifier = identifier
        self.name = name
        self.author = author
        self.version = version
        self.publishedAt = publishedAt
        self.downloadURL = downloadURL
        self.fileName = fileName
        self.summary = summary
        self.changelog = changelog
        self.screenshots = screenshots
    }

    /// The release to download for `ref`. Hosts have no release IDs, so the ID is derived
    /// from the version and `isUpdate` compares versions (`LatestReleaseStore.syntheticReleaseID`).
    func release(for ref: AddonRef) -> ResolvedRelease {
        ResolvedRelease(
            ref: ref, name: name, version: version,
            releaseID: LatestReleaseStore.syntheticReleaseID(ref: ref, tag: version),
            publishedAt: publishedAt, downloadURL: downloadURL, assetName: fileName, changelog: changelog,
            reasoning: ["\(ref.source.displayName) file \(fileName), version \(version)"],
            md5: md5?.lowercased()
        )
    }
}

enum HostedSources {
    /// Every hosted source, in display order.
    static let all: [any HostedSource] = [WoWInterface(), Tukui()]

    static func source(_ id: SourceID) -> (any HostedSource)? {
        all.first { $0.id == id }
    }

    /// The first hosted source that recognises `input`.
    static func parse(_ input: String) -> AddonRef? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        for source in all {
            if let ref = source.parse(text) { return ref }
        }
        return nil
    }

    /// `prefix:value` with a case-insensitive prefix, else nil.
    static func value(after prefix: String, in text: String) -> String? {
        guard text.lowercased().hasPrefix(prefix + ":") else { return nil }
        let value = String(text.dropFirst(prefix.count + 1))
        return value.isEmpty ? nil : value
    }

    /// The path of an http(s) URL on one of `hosts`, else nil. Accepts a missing scheme.
    static func path(of text: String, hosts: Set<String>) -> String? {
        let full = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: full),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), hosts.contains(host) else { return nil }
        return components.path + (components.query.map { "?" + $0 } ?? "")
    }
}

extension AddonRef {
    /// The add-on's page: the GitHub repo, or its page on WoWInterface or Tukui.
    public var webURL: URL? {
        switch source {
        case .github: URL(string: "https://github.com/\(identifier)")
        case .wowinterface, .tukui: HostedSources.source(source)?.webURL(for: identifier)
        }
    }
}
