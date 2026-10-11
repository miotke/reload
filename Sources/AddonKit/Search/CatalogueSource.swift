import Foundation

/// Downloads and caches `github-wow-addon-catalogue/addons.csv` (docs/design.md §7.2).
///
/// The parsed entries are stored as a binary property list next to the ETag and
/// fetch time. The cache is served for 24 h; after that the file is re-requested
/// with `If-None-Match`. A failed refresh falls back to a stale cache.
public actor CatalogueSource {
    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/layday/github-wow-addon-catalogue/main/addons.csv")!
    public static let cacheFileName = "catalogue.plist"
    public static let maxAge: TimeInterval = 24 * 60 * 60

    struct Cached: Codable {
        var entries: [CatalogueEntry]
        var etag: String?
        var fetchedAt: Date
    }

    private let http: any HTTPClient
    private let cacheURL: URL
    private let url: URL
    private let now: @Sendable () -> Date
    private var cached: Cached?
    private var loadedFromDisk = false
    private var generation = 0
    private var index: (generation: Int, value: SearchIndex)?
    private var inFlight: Task<[CatalogueEntry], any Error>?

    public init(
        http: any HTTPClient,
        cacheDirectory: URL,
        url: URL = CatalogueSource.defaultURL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.cacheURL = cacheDirectory.appending(path: Self.cacheFileName)
        self.url = url
        self.now = now
    }

    /// Catalogue entries, refreshed from the network at most once per 24 h.
    public func entries() async throws -> [CatalogueEntry] {
        loadFromDiskIfNeeded()
        if let cached, now().timeIntervalSince(cached.fetchedAt) < Self.maxAge {
            return cached.entries
        }
        // Coalesce concurrent callers onto one download.
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.refresh() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// A search index over `entries()`, rebuilt only when the entries change.
    public func searchIndex() async throws -> SearchIndex {
        let entries = try await entries()
        if let index, index.generation == generation { return index.value }
        let built = SearchIndex(entries: entries)
        index = (generation, built)
        return built
    }

    /// When the cached copy was last confirmed with the server, if any.
    public func lastFetched() -> Date? {
        loadFromDiskIfNeeded()
        return cached?.fetchedAt
    }

    private func refresh() async throws -> [CatalogueEntry] {
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag = cached?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await http.data(for: request)
            switch response.statusCode {
            case 304:
                guard var cached else { throw AddonError.http(status: 304, url: url) }
                cached.fetchedAt = now()
                store(cached)
                return cached.entries
            case 200:
                let entries = CatalogueCSV.entries(from: data)
                guard !entries.isEmpty else { throw AddonError.http(status: 200, url: url) }
                let etag = response.value(forHTTPHeaderField: "ETag")
                generation += 1
                store(Cached(entries: entries, etag: etag, fetchedAt: now()))
                return entries
            default:
                throw AddonError.http(status: response.statusCode, url: url)
            }
        } catch {
            if let cached { return cached.entries }
            throw error
        }
    }

    private func loadFromDiskIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        cached = try? PropertyListDecoder().decode(Cached.self, from: data)
    }

    private func store(_ value: Cached) {
        cached = value
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
