import Foundation
import Network
import Synchronization

/// Requests to github.com and raw.githubusercontent.com: no token, no API quota
/// (docs/network/github-endpoints.md).
///
/// - Retries 429 and 5xx with jittered backoff.
/// - A 429, or a 403 with `Retry-After`, that persists or asks for a long wait pauses every
///   web request until it's over; a 403 with neither header (a secondary limit) pauses for
///   at least 60 s.
/// - `background` requests stay off constrained (Low Data Mode) networks.
///
/// The raw lookups (`fetchLatestTag`, `fetchReleaseJSON`) are for `LatestReleaseStore` only,
/// the single owner of latest tags and verdicts; a test checks nothing else calls them.
public actor GitHubWebClient {
    /// Retries of a github.com request after a 429 or 5xx.
    static let maxRetries = 2

    static let base = URL(string: "https://github.com")!

    private let http: HTTPClient
    var now: @Sendable () -> Date = { Date() }
    /// Set after github.com keeps refusing; web requests fail fast until then.
    private var blockedUntil: Date?
    /// Delay before retry `attempt` (1-based), given the server's `Retry-After` if any.
    var retryDelay: @Sendable (_ attempt: Int, _ retryAfter: TimeInterval?) -> Duration = { attempt, retryAfter in
        // Jitter keeps concurrent checks from retrying in lockstep.
        .seconds(retryAfter ?? (Double(1 << attempt) + Double.random(in: 0..<0.5)))
    }

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) {
        now = clock
    }

    func setRetryDelay(_ delay: @escaping @Sendable (Int, TimeInterval?) -> Duration) {
        retryDelay = delay
    }

    /// True while github.com is pushing back and every web request fails fast.
    func isPaused() -> Bool {
        pausedUntil() != nil
    }

    /// When the current pause ends; nil when web requests aren't paused.
    public func pausedUntil() -> Date? {
        blockedUntil.flatMap { $0 > now() ? $0 : nil }
    }

    /// A request to github.com or raw.githubusercontent.com, with the pause and backoff above.
    func request(
        _ url: URL, method: String = "GET", accept: String? = nil, headers: [String: String] = [:],
        followRedirects: Bool = true, background: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            if let until = blockedUntil, until > now() { throw AddonError.rateLimited(resetAt: until) }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
            if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.allowsConstrainedNetworkAccess = !background
            let (data, response) = try await http.data(for: request, followRedirects: followRedirects)
            let status = response.statusCode
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }

            if status == 403, url.host() == "github.com" {
                let until = now().addingTimeInterval(max(retryAfter ?? 60, 60))
                blockedUntil = until
                throw AddonError.rateLimited(resetAt: until)
            }
            guard status == 429 || (500...599).contains(status) else { return (data, response) }

            attempt += 1
            if attempt > Self.maxRetries || (retryAfter ?? 0) > 30 {
                guard status == 429 else { throw AddonError.http(status: status, url: url) }
                let until = now().addingTimeInterval(retryAfter ?? 60)
                blockedUntil = until
                throw AddonError.rateLimited(resetAt: until)
            }
            try await Task.sleep(for: retryDelay(attempt, retryAfter))
        }
    }

    /// GET a `browser_download_url` (no API quota, no token). Not paused or retried.
    func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw AddonError.http(status: response.statusCode, url: url)
        }
        return data
    }

    // MARK: - Raw lookups (LatestReleaseStore only)

    /// Tag of the latest stable release (drafts and prereleases excluded), read from the
    /// `Location` of `github.com/<repo>/releases/latest` without following it (following
    /// would download the whole release page). Nil when the repo has no releases. Throws
    /// `notFound` for a missing repo.
    func fetchLatestTag(owner: String, repo: String, ref: AddonRef, background: Bool) async throws -> String? {
        let url = Self.base.appending(path: "\(owner)/\(repo)/releases/latest")
        let (_, response) = try await request(url, method: "HEAD", followRedirects: false, background: background)
        switch response.statusCode {
        case 300..<400:
            let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: url) }
            return Self.tag(fromReleaseURL: location)
        case 200..<300:
            // A client that followed the redirect anyway: the final URL carries the tag.
            return Self.tag(fromReleaseURL: response.url)
        case 404:
            throw AddonError.notFound(ref)
        default:
            throw AddonError.http(status: response.statusCode, url: url)
        }
    }

    /// release.json of the release tagged `tag` (nil if it has none), and when it was
    /// uploaded: the asset's `Last-Modified`, which is the release date without an API call.
    /// Not cached here: `LatestReleaseStore` stores it by `repo@tag`.
    func fetchReleaseJSON(owner: String, repo: String, tag: String, background: Bool) async throws -> (json: ReleaseJSON?, uploadedAt: Date?) {
        let url = Self.releaseDownloadURL(owner: owner, repo: repo, tag: tag, file: "release.json")
        let (data, response) = try await request(url, method: "GET", background: background)
        switch response.statusCode {
        case 200..<300: return (try ReleaseJSON(data: data), Self.lastModified(response))
        case 404: return (nil, nil)
        default: throw AddonError.http(status: response.statusCode, url: url)
        }
    }

    static func lastModified(_ response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Last-Modified") else { return nil }
        return try? Date(value, strategy: Date.HTTPFormatStyle())
    }

    /// `…/owner/repo/releases/tag/<tag>` → `<tag>`; anything else (a repo without releases
    /// lands on its plain releases page) → nil.
    static func tag(fromReleaseURL url: URL?) -> String? {
        guard let url else { return nil }
        let parts = url.absoluteURL.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[2] == "releases", parts[3] == "tag" else { return nil }
        return parts[4...].joined(separator: "/")
    }

    static func releaseDownloadURL(owner: String, repo: String, tag: String, file: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let escapedTag = tag.addingPercentEncoding(withAllowedCharacters: allowed) ?? tag
        let escapedFile = file.addingPercentEncoding(withAllowedCharacters: allowed) ?? file
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(escapedTag)/\(escapedFile)")!
    }
}

/// Whether the current network path is constrained (Low Data Mode), kept current by an
/// `NWPathMonitor` started on first use.
final class NetworkPathMonitor: Sendable {
    static let shared = NetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let constrained = Mutex(false)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.constrained.withLock { $0 = path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "Reload.network-path", qos: .utility))
    }

    var isConstrained: Bool { constrained.withLock { $0 } }
}
