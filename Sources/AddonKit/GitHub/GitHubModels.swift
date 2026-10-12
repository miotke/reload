import Foundation

/// One entry of `GET /repos/{owner}/{repo}/releases`. Only the fields the app uses are decoded.
public struct GitHubRelease: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var tagName: String
    public var name: String?
    public var draft: Bool
    public var prerelease: Bool
    public var createdAt: Date?
    public var publishedAt: Date?
    public var body: String?
    public var htmlURL: URL?
    public var assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case id, name, draft, prerelease, body, assets
        case tagName = "tag_name"
        case createdAt = "created_at"
        case publishedAt = "published_at"
        case htmlURL = "html_url"
    }

    public init(
        id: Int64, tagName: String, name: String? = nil, draft: Bool = false, prerelease: Bool = false,
        createdAt: Date? = nil, publishedAt: Date? = nil, body: String? = nil, htmlURL: URL? = nil,
        assets: [GitHubAsset] = []
    ) {
        self.id = id
        self.tagName = tagName
        self.name = name
        self.draft = draft
        self.prerelease = prerelease
        self.createdAt = createdAt
        self.publishedAt = publishedAt
        self.body = body
        self.htmlURL = htmlURL
        self.assets = assets
    }

    /// `"v426.4 (id 409811185)"`, used in reasoning trails.
    public var label: String { "\(tagName) (id \(id))" }

    /// Assets GitHub has finished receiving.
    public var uploadedAssets: [GitHubAsset] { assets.filter(\.isUploaded) }

    /// The BigWigs packager `release.json` asset, if one was uploaded.
    public var releaseJSONAsset: GitHubAsset? {
        uploadedAssets.first { $0.name.caseInsensitiveCompare("release.json") == .orderedSame }
    }

    /// Decodes a releases array as returned by the GitHub REST API.
    public static func decodeList(from data: Data) throws -> [GitHubRelease] {
        try decoder.decode([GitHubRelease].self, from: data)
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public struct GitHubAsset: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var name: String
    /// `uploaded` once complete; `open` while an upload is in progress.
    public var state: String
    public var size: Int
    public var contentType: String?
    public var browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case id, name, state, size
        case contentType = "content_type"
        case browserDownloadURL = "browser_download_url"
    }

    public init(id: Int64, name: String, state: String = "uploaded", size: Int = 0, contentType: String? = nil, browserDownloadURL: URL) {
        self.id = id
        self.name = name
        self.state = state
        self.size = size
        self.contentType = contentType
        self.browserDownloadURL = browserDownloadURL
    }

    public var isUploaded: Bool { state == "uploaded" }
}
