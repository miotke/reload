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
    let header = "id,name,full_name,url,description,last_updated,flavors,curse_id,wago_id,wowi_id,has_release_json,last_seen\n"

    func makeSource(_ http: StubHTTPClient, database: MetadataDatabase, clock: SearchTestClock) -> CatalogueSource {
        CatalogueSource(http: http, database: database, now: { clock.now })
    }

    @Test func fetchesStoresAndReopens() async throws {
        let dir = try makeTempDirectory()
        let database = try MetadataDatabase(url: dir.appending(path: MetadataDatabase.fileName))
        let http = StubHTTPClient()
        let clock = SearchTestClock()
        http.stub(url, headers: ["ETag": "\"abc\""], body: try fixtureData("search/addons.csv"))

        let source = makeSource(http, database: database, clock: clock)
        #expect(try await source.entries().count == 61)
        #expect(http.requests.count == 1)
        #expect(http.requests[0].value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
        #expect(http.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)

        // Fresh: no request.
        clock.advance(23 * 3600)
        _ = try await source.entries()
        #expect(http.requests.count == 1)

        // Another process opening the same file sees the rows without a request.
        let other = try MetadataDatabase(url: dir.appending(path: MetadataDatabase.fileName))
        #expect(try await makeSource(http, database: other, clock: clock).entries().count == 61)
        #expect(http.requests.count == 1)
    }

    @Test func staleCopyIsServedAtOnceAndRevalidatedWithETag() async throws {
        let http = StubHTTPClient()
        let clock = SearchTestClock()
        http.stub(url, headers: ["ETag": "\"abc\""], body: try fixtureData("search/addons.csv"))
        let source = makeSource(http, database: try .inMemory(), clock: clock)
        _ = try await source.entries()

        clock.advance(25 * 3600)
        http.stub(url, status: 304, body: Data())
        #expect(try await source.entries().count == 61)
        await source.waitForRevalidation()
        #expect(http.requests.count == 2)
        #expect(http.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(await source.lastFetched() == clock.now)

        clock.advance(3600)
        _ = try await source.entries()
        #expect(http.requests.count == 2)
    }

    @Test func failedFetchBacksOffFifteenMinutes() async throws {
        let http = StubHTTPClient()
        let clock = SearchTestClock()
        http.stub(url, body: try fixtureData("search/addons.csv"))
        let database = try MetadataDatabase.inMemory()
        _ = try await makeSource(http, database: database, clock: clock).entries()

        clock.advance(48 * 3600)
        http.stub(url, status: 500, body: Data())
        let source = makeSource(http, database: database, clock: clock)
        #expect(try await source.entries().count == 61)
        await source.waitForRevalidation()
        #expect(http.requests.count == 2)

        // Within the backoff, neither entries() nor refresh() tries again.
        clock.advance(10 * 60)
        _ = try await source.entries()
        _ = try await source.refresh()
        await source.waitForRevalidation()
        #expect(http.requests.count == 2)

        clock.advance(6 * 60)
        _ = try? await source.refresh()
        #expect(http.requests.count == 3)
    }

    @Test func failsWithoutStoredRows() async throws {
        let http = StubHTTPClient()
        http.stub(url, status: 503, body: Data())
        let source = makeSource(http, database: try .inMemory(), clock: SearchTestClock())
        await #expect(throws: AddonError.http(status: 503, url: CatalogueSource.defaultURL)) {
            try await source.entries()
        }
        // Backing off: no second request.
        await #expect(throws: (any Error).self) { try await source.entries() }
        #expect(http.requests.count == 1)
    }

    @Test func refreshReportsWhatChanged() async throws {
        let http = StubHTTPClient()
        let clock = SearchTestClock()
        let v1 = header + """
            1,A,o/A,https://github.com/o/A,,2026-01-01T00:00:00Z,,,,,True,
            2,B,o/B,https://github.com/o/B,,2026-01-01T00:00:00Z,,,,,True,
            3,C,o/C,https://github.com/o/C,,2026-01-01T00:00:00Z,,,,,False,

            """
        http.stub(url, body: Data(v1.utf8))
        let source = makeSource(http, database: try .inMemory(), clock: clock)
        let first = try await source.refresh(force: true)
        #expect(first.changed == ["o/A", "o/B", "o/C"])

        let v2 = header + """
            1,A,o/A,https://github.com/o/A,,2026-01-01T00:00:00Z,,,,,True,
            2,B,o/B,https://github.com/o/B,,2026-02-01T00:00:00Z,,,,,True,
            4,D,o/D,https://github.com/o/D,,2026-02-01T00:00:00Z,,,,,True,

            """
        http.stub(url, body: Data(v2.utf8))
        let second = try await source.refresh(force: true)
        #expect(second.changed == ["o/B", "o/D"])
        #expect(second.removed == ["o/C"])
        #expect(try await source.searchIndex().count == 3)
        #expect(try await source.searchIndex().search("d").map(\.fullName) == ["o/D"])
    }

    @Test func liveResultsAreKeptAcrossCatalogueUpdates() async throws {
        let http = StubHTTPClient()
        http.stub(url, body: try fixtureData("search/addons.csv"))
        let source = makeSource(http, database: try .inMemory(), clock: SearchTestClock())
        try await source.remember(liveResults: [
            CatalogueEntry(id: "x/Live", name: "Live", fullName: "x/Live", url: URL(string: "https://github.com/x/Live")!, fromLiveSearch: true),
        ])
        _ = try await source.refresh(force: true)
        let live = try #require(await source.entry(for: AddonRef(source: .github, identifier: "x/live")))
        #expect(live.fromLiveSearch)
        #expect(try await source.entries().count == 62)
    }

    @Test func importOfTheFullCatalogueIsFast() async throws {
        // ~2.4k rows, like the real file.
        var csv = header
        for i in 0..<2_400 {
            csv += "\(i),Addon\(i),owner\(i % 300)/Addon\(i),https://github.com/owner\(i % 300)/Addon\(i),Description \(i),2026-0\(i % 9 + 1)-01T00:00:00Z,mainline,,,,\(i % 2 == 0 ? "True" : "False"),\n"
        }
        let entries = CatalogueCSV.entries(from: Data(csv.utf8))
        #expect(entries.count == 2_400)
        let database = try MetadataDatabase.inMemory()

        let clock = ContinuousClock()
        let first = try await clock.measure { _ = try await database.importCatalogue(entries, etag: nil, at: Date()) }
        let unchanged = try await clock.measure { _ = try await database.importCatalogue(entries, etag: nil, at: Date()) }
        #expect(first < .milliseconds(500), "first import took \(first)")
        #expect(unchanged < .milliseconds(250), "re-import took \(unchanged)")
        let read = try await clock.measure { _ = try await database.catalogueEntries() }
        #expect(read < .milliseconds(250), "reading took \(read)")
    }
}
