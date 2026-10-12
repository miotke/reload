import Foundation

/// An add-on host that can resolve a ref to its newest compatible release (docs/design.md §6.4).
public protocol Source: Sendable {
    var id: SourceID { get }

    /// Turn user input (`owner/repo`, a URL) into a ref, or nil if it isn't ours.
    func parse(_ input: String) -> AddonRef?

    /// Newest release of `ref` that supports `flavor` on `channel`.
    /// Pass the stored `etag` to get `.notModified` cheaply.
    /// Throws `AddonError.noCompatibleRelease` if no release supports `flavor`.
    func resolve(_ ref: AddonRef, flavor: Flavor, channel: Channel, etag: String?) async throws -> ResolveResult
}

/// Minimal HTTP abstraction so sources can be tested with fixtures.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// With `followRedirects: false`, a 3xx comes back as is, with its `Location` header.
    func data(for request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse)
}

extension HTTPClient {
    /// Clients that can't stop at a redirect follow it; callers then read the final `url`.
    public func data(for request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        try await data(for: request)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public let session: URLSession

    public init(session: URLSession = URLSessionHTTPClient.sharedSession) {
        self.session = session
    }

    /// One session for the whole core: 20 s request timeout, fail fast when offline, no
    /// HTTP cache (ETags are handled explicitly), and the app's User-Agent.
    public static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent]
        return URLSession(configuration: configuration)
    }()

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await data(for: request, followRedirects: true)
    }

    public func data(for request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: followRedirects ? nil : NoRedirects.shared)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// Stops at the first redirect so its `Location` can be read without fetching the target.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirects()

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

public enum AppInfo {
    public static let name = "ForeverAddons"
    public static let bundleID = "com.andrewmiotke.ForeverAddons"
    public static let version = "0.1.0"
    public static let contactURL = "https://github.com/miotke/swift-addons"
    public static var userAgent: String { "\(name)/\(version) (+\(contactURL))" }
}
