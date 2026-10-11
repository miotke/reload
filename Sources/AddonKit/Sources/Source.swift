import Foundation

/// An add-on host that can resolve a ref to its newest compatible release (DESIGN.md §6.4).
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
}

public struct URLSessionHTTPClient: HTTPClient {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

public enum AppInfo {
    public static let name = "ForeverAddons"
    public static let bundleID = "com.andrewmiotke.ForeverAddons"
    public static let version = "0.1.0"
    public static var userAgent: String { "\(name)/\(version)" }
}
