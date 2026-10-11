import Foundation
import Synchronization
import Testing
@testable import AddonKit

/// Serves canned bodies by URL string and counts requests.
final class StubDownloadTransport: DownloadTransport, Sendable {
    private struct State {
        var bodies: [String: Data] = [:]
        var requests: [URL] = []
        var delay: Duration = .zero
    }

    private let state = Mutex(State())

    var delay: Duration {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue } }
    }

    var requests: [URL] { state.withLock { $0.requests } }

    func stub(_ url: URL, _ body: Data) { state.withLock { $0.bodies[url.absoluteString] = body } }

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (body, delay) = state.withLock { state -> (Data?, Duration) in
            state.requests.append(url)
            return (state.bodies[url.absoluteString], state.delay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let body else { throw AddonError.http(status: 404, url: url) }
        progress(0.5)
        try body.write(to: destination)
    }
}

/// Serves `https://stub.test/...` URLs to a URLSession configured with this protocol.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let route = Self.lock.withLock { Self.routes[url.absoluteString] } ?? (404, Data())
        let response = HTTPURLResponse(url: url, statusCode: route.0, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(route.1.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Two chunks so progress has something to report.
        let half = route.1.count / 2
        client?.urlProtocol(self, didLoad: route.1.prefix(half))
        client?.urlProtocol(self, didLoad: route.1.dropFirst(half))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func release(_ id: Int64, identifier: String = "Owner/Repo", url: String? = nil) -> ResolvedRelease {
    ResolvedRelease(
        ref: AddonRef(source: .github, identifier: identifier), name: "Repo", version: "v\(id)", releaseID: id,
        publishedAt: Date(timeIntervalSince1970: TimeInterval(id)),
        downloadURL: URL(string: url ?? "https://example.com/\(id).zip")!, assetName: "Repo-v\(id).zip"
    )
}

@Suite struct DownloaderTests {
    @Test func downloadsIntoCacheLayoutAndReuses() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let transport = StubDownloadTransport()
        let r = release(7)
        transport.stub(r.downloadURL, Data("zip7".utf8))
        let downloader = Downloader(cachesDirectory: tmp, transport: transport)

        let values = LockedBox<[Double]>([])
        let url = try await downloader.download(r) { p in values.withValue { $0.append(p) } }
        #expect(url == tmp.appending(path: "downloads/github/Owner+Repo/7-Repo-v7.zip"))
        #expect(try Data(contentsOf: url) == Data("zip7".utf8))
        #expect(values.value == [0.5, 1])

        let again = try await downloader.download(r)
        #expect(again == url)
        #expect(transport.requests.count == 1)

        // No partial files left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path(percentEncoded: false))
        #expect(names == ["7-Repo-v7.zip"])
    }

    @Test func keepsNewestTwoAndListsNewestFirst() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let transport = StubDownloadTransport()
        let downloader = Downloader(cachesDirectory: tmp, transport: transport)
        let ref = AddonRef(source: .github, identifier: "Owner/Repo")
        #expect(await downloader.cachedArchives(for: ref).isEmpty)

        for id: Int64 in 1...3 {
            let r = release(id)
            transport.stub(r.downloadURL, Data("zip\(id)".utf8))
            _ = try await downloader.download(r)
        }
        #expect(await downloader.cachedArchives(for: ref).map(\.lastPathComponent) == ["3-Repo-v3.zip", "2-Repo-v2.zip"])

        // Reusing v2 marks it newest; downloading v4 then drops v3.
        _ = try await downloader.download(release(2))
        let r4 = release(4)
        transport.stub(r4.downloadURL, Data("zip4".utf8))
        _ = try await downloader.download(r4)
        #expect(await downloader.cachedArchives(for: ref).map(\.lastPathComponent) == ["4-Repo-v4.zip", "2-Repo-v2.zip"])

        // Other add-ons are untouched.
        let other = release(1, identifier: "Other/Thing", url: "https://example.com/other.zip")
        transport.stub(other.downloadURL, Data("o".utf8))
        _ = try await downloader.download(other)
        #expect(await downloader.cachedArchives(for: ref).count == 2)
        #expect(await downloader.cachedArchives(for: other.ref).count == 1)
    }

    @Test func failedDownloadLeavesNothing() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let downloader = Downloader(cachesDirectory: tmp, transport: StubDownloadTransport())
        let r = release(1)
        await #expect(throws: AddonError.http(status: 404, url: r.downloadURL)) { try await downloader.download(r) }
        #expect(await downloader.cachedArchives(for: r.ref).isEmpty)
        let dir = downloader.archiveURL(for: r).deletingLastPathComponent().path(percentEncoded: false)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).isEmpty)
    }

    @Test func concurrentRequestsForSameReleaseShareOneDownload() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let transport = StubDownloadTransport()
        transport.delay = .milliseconds(50)
        let r = release(1)
        transport.stub(r.downloadURL, Data("z".utf8))
        let downloader = Downloader(cachesDirectory: tmp, transport: transport)
        async let a = downloader.download(r)
        async let b = downloader.download(r)
        let (ua, ub) = try await (a, b)
        #expect(ua == ub)
        #expect(transport.requests.count == 1)
    }

    @Test func sanitizesPathComponents() {
        #expect(Downloader.sanitize("../../etc") == "_._.._etc")
        #expect(Downloader.sanitize("a b/c") == "a_b_c")
        #expect(Downloader.sanitize("") == "_")
        let downloader = Downloader(cachesDirectory: URL(filePath: "/c"), transport: StubDownloadTransport())
        let evil = ResolvedRelease(ref: AddonRef(source: .github, identifier: ".."), name: "x", version: "1", releaseID: 1,
                                   publishedAt: .now, downloadURL: URL(string: "https://e.com")!, assetName: "../x.zip")
        #expect(downloader.archiveURL(for: evil).path == "/c/downloads/github/_./1-.._x.zip")
    }

    @Test func urlSessionTransportReportsProgressAndHTTPErrors() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let body = Data(repeating: 7, count: 64 * 1024)
        StubURLProtocol.lock.withLock {
            StubURLProtocol.routes["https://stub.test/ok.zip"] = (200, body)
            StubURLProtocol.routes["https://stub.test/missing.zip"] = (404, Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let transport = URLSessionDownloadTransport(session: URLSession(configuration: config))

        let values = LockedBox<[Double]>([])
        let destination = tmp.appending(path: "ok.zip")
        try await transport.download(from: URL(string: "https://stub.test/ok.zip")!, to: destination) { p in
            values.withValue { $0.append(p) }
        }
        #expect(try Data(contentsOf: destination) == body)
        #expect(values.value.allSatisfy { (0...1).contains($0) })

        let missing = URL(string: "https://stub.test/missing.zip")!
        await #expect(throws: AddonError.http(status: 404, url: missing)) {
            try await transport.download(from: missing, to: tmp.appending(path: "missing.zip")) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.appending(path: "missing.zip").path(percentEncoded: false)))
    }
}
