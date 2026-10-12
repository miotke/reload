import Foundation

/// The GitHub pieces wired over one HTTP client and database (docs/architecture/core.md).
/// Callers use the pieces directly; this only builds them and sets their clock.
public struct GitHub: Sendable {
    /// `api.github.com`: token, rate limit, releases lists.
    public let api: GitHubAPIClient
    /// github.com and raw.githubusercontent.com: pause and backoff.
    public let web: GitHubWebClient
    /// Resolves over the releases API, with zip inspection.
    public let source: GitHubSource
    /// The single owner of verdicts, latest tags and available flavors.
    public let latest: LatestReleaseStore
    public let readmes: ReadmeFetcher

    /// - Parameters:
    ///   - database: shares the API rate-limit state with other processes and holds the
    ///     support verdicts (an in-memory database is used without one).
    ///   - store: the `SupportCache` `latest` owns; by default one over `database`.
    ///   - tokenProvider: read once, on the first API call, when `token` is nil.
    ///   - archiveURL: where to keep inspected zips (`Downloader.archiveURL(for:)`).
    public init(
        http: HTTPClient = URLSessionHTTPClient(), token: String? = nil, cacheDirectory: URL? = nil,
        database: MetadataDatabase? = nil, store: SupportCache? = nil, tokenProvider: (@Sendable () -> String?)? = nil,
        archiveURL: (@Sendable (ResolvedRelease) -> URL)? = nil
    ) {
        let metadata = database ?? (try! MetadataDatabase.inMemory())
        let store = store ?? SupportCache(database: metadata)
        api = GitHubAPIClient(http: http, token: token, database: database, store: store, tokenProvider: tokenProvider)
        web = GitHubWebClient(http: http)
        source = GitHubSource(api: api, web: web, cacheDirectory: cacheDirectory, archiveURL: archiveURL)
        latest = LatestReleaseStore(store: store, web: web, api: api, source: source)
        readmes = ReadmeFetcher(web: web, api: api, database: metadata)
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) async {
        await api.setClock(clock)
        await web.setClock(clock)
        await latest.setClock(clock)
    }
}
