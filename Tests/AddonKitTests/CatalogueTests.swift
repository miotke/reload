import Foundation
import Testing
@testable import AddonKit

/// A mutable clock for cache-expiry tests.
final class SearchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now += seconds } }
}

@Suite struct CatalogueTests {
    let url = CatalogueSource.defaultURL.absoluteString

    func makeSource(_ http: StubHTTPClient, dir: URL, clock: SearchTestClock) -> CatalogueSource {
        CatalogueSource(http: http, cacheDirectory: dir, now: { clock.now })
    }

    @Test func fetchesParsesAndCaches() async throws {
        let dir = try makeTempDirectory()
        let http = StubHTTPClient()
        let clock = SearchTestClock()
        http.stub(url, headers: ["ETag": "\"abc\""], body: try fixtureData("search/addons.csv"))

        let source = makeSource(http, dir: dir, clock: clock)
        let entries = try await source.entries()
        #expect(entries.count == 200)
        #expect(http.requests.count == 1)
        #expect(http.requests[0].value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
        #expect(http.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: CatalogueSource.cacheFileName).path))

        // Fresh: served from memory.
        clock.advance(23 * 3600)
        _ = try await source.entries()
        #expect(http.requests.count == 1)

        // A new instance reads the disk cache without a request.
        let reopened = makeSource(http, dir: dir, clock: clock)
        #expect(try await reopened.entries().count == 200)
        #expect(http.requests.count == 1)
    }

    @Test func expiredCacheRevalidatesWithETag() async throws {
        let dir = try makeTempDirectory()
        let http = StubHTTPClient()
        let clock = SearchTestClock()
        http.stub(url, headers: ["ETag": "\"abc\""], body: try fixtureData("search/addons.csv"))
        let source = makeSource(http, dir: dir, clock: clock)
        _ = try await source.entries()

        clock.advance(25 * 3600)
        http.stub(url, status: 304, body: Data())
        #expect(try await source.entries().count == 200)
        #expect(http.requests.count == 2)
        #expect(http.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(await source.lastFetched() == clock.now)

        // 304 refreshed the timestamp, so the next call is served from cache.
        clock.advance(3600)
        _ = try await source.entries()
        #expect(http.requests.count == 2)
    }

    @Test func staleCacheIsServedWhenNetworkFails() async throws {
        let dir = try makeTempDirectory()
        let http = StubHTTPClient()
        let clock = SearchTestClock()
        http.stub(url, body: try fixtureData("search/addons.csv"))
        _ = try await makeSource(http, dir: dir, clock: clock).entries()

        clock.advance(48 * 3600)
        http.stub(url, status: 500, body: Data())
        let source = makeSource(http, dir: dir, clock: clock)
        #expect(try await source.entries().count == 200)
        #expect(http.requests.count == 2)
    }

    @Test func failsWithoutCache() async throws {
        let http = StubHTTPClient()
        http.stub(url, status: 503, body: Data())
        let source = makeSource(http, dir: try makeTempDirectory(), clock: SearchTestClock())
        await #expect(throws: AddonError.http(status: 503, url: CatalogueSource.defaultURL)) {
            try await source.entries()
        }
    }

    @Test func updatedCatalogueReplacesEntriesAndIndex() async throws {
        let dir = try makeTempDirectory()
        let http = StubHTTPClient()
        let clock = SearchTestClock()
        http.stub(url, body: try fixtureData("search/addons.csv"))
        let source = makeSource(http, dir: dir, clock: clock)
        let first = try await source.searchIndex()
        #expect(first.count == 200)

        let small = "id,name,full_name,url,description,last_updated,flavors,curse_id,wago_id,wowi_id,has_release_json,last_seen\n1,Solo,a/Solo,https://github.com/a/Solo,,,,,,,False,\n"
        clock.advance(25 * 3600)
        http.stub(url, body: Data(small.utf8))
        let second = try await source.searchIndex()
        #expect(second.count == 1)
        #expect(second.search("solo").count == 1)
    }
}
