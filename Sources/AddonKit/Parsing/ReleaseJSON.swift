import Foundation

/// BigWigs packager `release.json` (DESIGN.md §2).
public struct ReleaseJSON: Codable, Sendable, Hashable {
    public struct Release: Codable, Sendable, Hashable {
        public var name: String?
        public var version: String?
        public var filename: String
        public var nolib: Bool
        public var metadata: [Metadata]

        public init(name: String? = nil, version: String? = nil, filename: String, nolib: Bool, metadata: [Metadata]) {
            self.name = name
            self.version = version
            self.filename = filename
            self.nolib = nolib
            self.metadata = metadata
        }

        /// True if any metadata entry targets `flavor`.
        public func supports(_ flavor: Flavor) -> Bool {
            metadata.contains { flavor.rules.releaseJSONFlavors.contains($0.flavor.lowercased()) }
        }
    }

    public struct Metadata: Codable, Sendable, Hashable {
        public var flavor: String
        public var interface: Int

        public init(flavor: String, interface: Int) {
            self.flavor = flavor
            self.interface = interface
        }
    }

    public var releases: [Release]

    public init(releases: [Release]) {
        self.releases = releases
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(ReleaseJSON.self, from: data)
    }

    /// The first full (non-nolib) release that supports `flavor`.
    public func release(for flavor: Flavor) -> Release? {
        releases.first { !$0.nolib && $0.supports(flavor) }
    }
}
