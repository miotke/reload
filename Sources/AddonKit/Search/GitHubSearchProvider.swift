import Foundation

/// Live GitHub repository search (docs/design.md §7.4).
///
/// Runs `topic:wow-addon` first, then `topic:world-of-warcraft-addon`, then a
/// topic-less `wow OR warcraft` query while fewer than `minimumResults` repos were
/// found. Archived repos and forks are dropped. Results are cached per query text
/// for 10 minutes. A 403/429 throws `AddonError.rateLimited`; if a fallback stage fails
/// after earlier stages found repos, those are returned (and not cached).
public actor GitHubSearchProvider: SearchProvider {
    public static let endpoint = "https://api.github.com/search/repositories"
    public static let cacheTTL: TimeInterval = 10 * 60
    public static let minimumResults = 5

    private let http: any HTTPClient
    private var token: String?
    private let database: MetadataDatabase?
    private let now: @Sendable () -> Date
    private var cache: [String: (fetchedAt: Date, results: [SearchResult])] = [:]

    /// `database` shares the search rate-limit state (10/min without a token, 30/min with
    /// one) with other processes, so a limit hit by the CLI also pauses the app.
    /// `tokenProvider` is read on first use when `token` is nil.
    public init(
        http: any HTTPClient, token: String? = nil, database: MetadataDatabase? = nil,
        tokenProvider: (@Sendable () -> String?)? = nil, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.token = token
        self.tokenProvider = token == nil ? tokenProvider : nil
        self.database = database
        self.now = now
    }

    private var tokenProvider: (@Sendable () -> String?)?

    public func setToken(_ token: String?) {
        self.token = token
        tokenProvider = nil
        cache = [:]
    }

    private func currentToken() -> String? {
        if let tokenProvider {
            token = tokenProvider()
            self.tokenProvider = nil
        }
        return token
    }

    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        try await search(query, stages: nil)
    }

    /// Like `search(_:)`, but tries at most `stages` of the fallback queries (nil: all).
    public func search(_ query: SearchQuery, stages: Int?) async throws -> [SearchResult] {
        let terms = Self.terms(query.text)
        guard !terms.isEmpty else { return [] }
        let cacheKey = "\(stages ?? 0)#\(terms)"
        if let hit = cache[cacheKey], now().timeIntervalSince(hit.fetchedAt) < Self.cacheTTL {
            return hit.results
        }
        if let state = await database?.rateLimit("search"), state.isExhausted(at: now()) {
            throw AddonError.rateLimited(resetAt: state.resetAt)
        }

        var results: [SearchResult] = []
        var seen = Set<String>()
        var complete = true
        for q in Self.queries(for: terms).prefix(stages ?? Int.max) {
            let page: [SearchResult]
            do {
                page = try await fetch(q)
            } catch {
                // A failed fallback stage keeps what earlier stages found.
                if !results.isEmpty { complete = false; break }
                throw error
            }
            for result in page where seen.insert(result.id.identifier.lowercased()).inserted {
                results.append(result)
            }
            if results.count >= Self.minimumResults { break }
        }
        if complete { cache[cacheKey] = (now(), results) }
        return results
    }

    /// Drops cached results (e.g. after the user adds a token).
    public func clearCache() {
        cache = [:]
    }

    // MARK: Query building

    /// The user's words with whitespace collapsed; search qualifiers they typed are kept.
    static func terms(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The `q=` values tried in order.
    static func queries(for terms: String) -> [String] {
        [
            "\(terms) in:name,description topic:wow-addon",
            "\(terms) in:name,description topic:world-of-warcraft-addon",
            "\(terms) in:name,description wow OR warcraft",
        ]
    }

    /// Percent-encodes everything except RFC 3986 unreserved characters; spaces become `+`.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        allowed.insert(" ")
        let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return escaped.replacingOccurrences(of: " ", with: "+")
    }

    public static func url(forQuery q: String) -> URL {
        URL(string: "\(endpoint)?q=\(encode(q))&sort=updated&per_page=30")!
    }

    // MARK: Fetching

    private struct Response: Decodable {
        struct Item: Decodable {
            struct Owner: Decodable { var login: String }
            var name: String
            var full_name: String
            var description: String?
            var owner: Owner?
            var stargazers_count: Int?
            var pushed_at: Date?
            var updated_at: Date?
            var archived: Bool?
            var fork: Bool?
        }
        var items: [Item]
    }

    private func fetch(_ q: String) async throws -> [SearchResult] {
        let url = Self.url(forQuery: q)
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if let token = currentToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await http.data(for: request)
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        switch response.statusCode {
        case 200:
            if let remaining {
                await database?.setRateLimit("search", RateLimitState(remaining: remaining, resetAt: Self.resetDate(response, now: now())), at: now())
            }
        case 403, 429:
            // A secondary limit may carry neither header; wait at least a minute then.
            let reset = Self.resetDate(response, now: now()) ?? now().addingTimeInterval(60)
            await database?.setRateLimit("search", RateLimitState(remaining: 0, resetAt: reset), at: now())
            throw AddonError.rateLimited(resetAt: reset)
        default:
            throw AddonError.http(status: response.statusCode, url: url)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Response.self, from: data)
        return decoded.items.compactMap { item in
            guard item.archived != true, item.fork != true else { return nil }
            let owner = item.owner?.login ?? String(item.full_name.split(separator: "/").first ?? "")
            return SearchResult(
                id: AddonRef(source: .github, identifier: item.full_name),
                name: item.name,
                summary: item.description,
                owner: owner,
                stars: item.stargazers_count,
                lastUpdated: item.pushed_at ?? item.updated_at,
                support: .unknown,
                origin: [.github]
            )
        }
    }

    static func resetDate(_ response: HTTPURLResponse, now: Date) -> Date? {
        if let retry = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(retry) {
            return now.addingTimeInterval(seconds)
        }
        if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"), let epoch = TimeInterval(reset) {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }
}
