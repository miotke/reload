import Foundation

/// The README of a repo, quota-free from raw.githubusercontent.com
/// (docs/features/details-and-screenshots.md). Owns the remembered path and ETag and the
/// "no README" negative cache in `repo_meta`.
public struct ReadmeFetcher: Sendable {
    public enum Result: Sendable, Hashable {
        /// `etag` and `path` are what to send next time.
        case found(markdown: String, path: String, etag: String?)
        /// The stored copy at `knownPath` is still current.
        case notModified
        /// The repo has no README anywhere we look.
        case none
    }

    /// Where GitHub looks for a README, most common first. `HEAD` on raw.githubusercontent.com
    /// is the default branch, which the catalogue doesn't tell us.
    public static let candidates = [
        "README.md", ".github/README.md", "readme.md", "Readme.md", "docs/README.md",
        "README.markdown", "README.MD", "README",
    ]
    /// Longer READMEs are cut at a line break below this size.
    public static let maxBytes = 512 * 1024
    /// A repo found to have no README isn't asked again for this long.
    public static let noReadmeTTL: TimeInterval = 7 * 24 * 60 * 60

    let web: GitHubWebClient
    let api: GitHubAPIClient
    let database: MetadataDatabase

    public init(web: GitHubWebClient, api: GitHubAPIClient, database: MetadataDatabase) {
        self.web = web
        self.api = api
        self.database = database
    }

    /// The current README of `ref`, using what `repo_meta` remembers: the known path first,
    /// with its ETag when `previous` (the stored README) is there to fall back on. A repo found
    /// to have none within `noReadmeTTL` isn't asked again. Writes what it learns.
    /// - Returns: the markdown and its path, both nil when there's no README.
    /// - Throws: when the README couldn't be fetched.
    func current(for ref: AddonRef, previous: String?, now: Date) async throws -> (markdown: String?, path: String?) {
        // A stored "none" is an empty path.
        let meta = try? await database.query(
            "SELECT readme_path, readme_etag, readme_checked_at FROM repo_meta WHERE full_name = ?", ref.identifier).first
        let knownPath = meta?.string(0)
        if knownPath == "", let checked = meta?.date(2), now.timeIntervalSince(checked) < Self.noReadmeTTL {
            // Recently found to have none: don't walk the candidate paths again.
            return (nil, nil)
        }
        switch try await fetch(for: ref, knownPath: knownPath, etag: previous == nil ? nil : meta?.string(1)) {
        case .found(let markdown, let path, let etag):
            _ = try? await database.execute("""
                INSERT INTO repo_meta(full_name, readme_path, readme_etag, readme_checked_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(full_name) DO UPDATE SET readme_path = excluded.readme_path,
                    readme_etag = excluded.readme_etag, readme_checked_at = excluded.readme_checked_at
                """, ref.identifier, path, etag, now)
            return (markdown, path)
        case .notModified:
            return (previous, knownPath)
        case .none:
            _ = try? await database.execute("""
                INSERT INTO repo_meta(full_name, readme_path, readme_etag, readme_checked_at) VALUES (?, '', NULL, ?)
                ON CONFLICT(full_name) DO UPDATE SET readme_path = '', readme_etag = NULL, readme_checked_at = excluded.readme_checked_at
                """, ref.identifier, now)
            return (nil, nil)
        }
    }

    /// The README of `ref`, without reading or writing `repo_meta`. A known path is tried
    /// first (with its ETag, so an unchanged README is a 304). Only with a token, and only
    /// when every candidate 404s, is the API's `/readme` asked (1 call).
    public func fetch(for ref: AddonRef, knownPath: String? = nil, etag: String? = nil) async throws -> Result {
        let (owner, repo) = try GitHubSource.split(ref)
        var candidates = Self.candidates
        if let knownPath, !knownPath.isEmpty {
            candidates.removeAll { $0 == knownPath }
            candidates.insert(knownPath, at: 0)
        }
        for path in candidates {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(encoded)")!
            var headers: [String: String] = [:]
            if path == knownPath, let etag { headers["If-None-Match"] = etag }
            let (data, response) = try await web.request(url, headers: headers)
            switch response.statusCode {
            case 304:
                return .notModified
            case 200..<300:
                return .found(markdown: Self.capped(data), path: path, etag: response.value(forHTTPHeaderField: "ETag"))
            case 404:
                continue
            default:
                throw AddonError.http(status: response.statusCode, url: url)
            }
        }
        guard await api.hasToken(), await api.quotaIsComfortable() else { return .none }
        struct Readme: Decodable { var path: String; var content: String?; var encoding: String? }
        let url = GitHubAPIClient.base.appending(path: "repos/\(owner)/\(repo)/readme")
        let (data, response) = try await api.get(url)
        guard response.statusCode == 200, let readme = try? JSONDecoder().decode(Readme.self, from: data),
              let content = readme.content, readme.encoding == "base64",
              let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return .none }
        return .found(markdown: Self.capped(decoded), path: readme.path, etag: nil)
    }

    static func capped(_ data: Data) -> String {
        guard data.count > maxBytes else { return String(decoding: data, as: UTF8.self) }
        var cut = data.prefix(maxBytes)
        if let newline = cut.lastIndex(of: UInt8(ascii: "\n")) { cut = cut[..<newline] }
        return String(decoding: cut, as: UTF8.self)
    }
}
