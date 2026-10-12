import Foundation
import Testing
@testable import AddonKit

/// A GitHub `/search/repositories` body.
func githubSearchBody(_ repos: [(fullName: String, stars: Int, archived: Bool, fork: Bool)]) -> Data {
    let items = repos.map { repo -> [String: Any] in
        let parts = repo.fullName.split(separator: "/")
        return [
            "name": String(parts[1]),
            "full_name": repo.fullName,
            "description": "About \(parts[1])",
            "owner": ["login": String(parts[0])],
            "stargazers_count": repo.stars,
            "pushed_at": "2026-09-01T12:00:00Z",
            "updated_at": "2026-09-02T12:00:00Z",
            "archived": repo.archived,
            "fork": repo.fork,
        ]
    }
    return try! JSONSerialization.data(withJSONObject: ["total_count": items.count, "items": items])
}

func githubSearchBody(_ names: [String]) -> Data {
    githubSearchBody(names.map { ($0, 10, false, false) })
}

func sampleInstalledAddon(_ identifier: String, name: String, folders: [String]) -> InstalledAddon {
    InstalledAddon(
        id: AddonRef(source: .github, identifier: identifier), name: name, folders: folders, version: "v1",
        releaseID: 1, assetName: "a.zip", publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        installedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
}

@Suite struct SupportCacheTests {
    let bw = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs")
    let dbm = AddonRef(source: .github, identifier: "DeadlyBossMods/DeadlyBossMods")

    @Test func storesAndPersistsStatuses() async throws {
        let dir = try makeTempDirectory()
        let clock = SearchTestClock()
        let cache = SupportCache(directory: dir, now: { clock.now })
        await cache.set(.supported(version: "v1.2"), for: bw, tag: "v1.2")
        await cache.set(.unsupported, for: dbm)
        #expect(await cache.status(for: bw) == .supported(version: "v1.2"))
        #expect(await cache.status(for: bw, flavor: .mainline) == nil)
        #expect(await cache.record(for: bw)?.tag == "v1.2")

        let reopened = SupportCache(directory: dir, now: { clock.now })
        #expect(await reopened.status(for: AddonRef(source: .github, identifier: "bigwigsmods/bigwigs")) == .supported(version: "v1.2"))
        #expect(await reopened.status(for: dbm) == .unsupported)
        #expect(await reopened.statuses().count == 2)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: MetadataDatabase.fileName).path))
    }

    @Test func verdictsStayVisibleButGoStaleAfterADay() async throws {
        let clock = SearchTestClock()
        let cache = SupportCache(database: try .inMemory(), now: { clock.now })
        await cache.set(.noReleases, for: bw)
        clock.advance(23 * 3600)
        #expect(await cache.isFresh(bw))
        clock.advance(2 * 3600)
        #expect(!(await cache.isFresh(bw)))
        #expect(await cache.status(for: bw) == .noReleases)
    }

    @Test func failuresAreRememberedBrieflyAndNeverShown() async throws {
        let clock = SearchTestClock()
        let cache = SupportCache(database: try .inMemory(), now: { clock.now })
        await cache.set(.needsDownload, for: bw)
        await cache.set(.checking, for: bw)
        await cache.set(.unknown, for: dbm)
        #expect(await cache.status(for: bw) == .needsDownload)
        #expect(await cache.status(for: dbm) == nil)
        #expect(await cache.statuses().keys.map(\.identifier) == ["BigWigsMods/BigWigs"])
        #expect(await cache.isFresh(dbm))
        clock.advance(16 * 60)
        #expect(!(await cache.isFresh(dbm)))
    }

    @Test func tagAndStars() async throws {
        let cache = SupportCache(database: try .inMemory())
        await cache.setLatestTag("v2", for: bw)
        #expect(await cache.latestTag(for: bw)?.tag == "v2")
        await cache.setLatestTag(nil, for: dbm)
        #expect(await cache.latestTag(for: dbm)?.tag == nil)
        await cache.setStars([bw: 900])
        #expect(await cache.stars()["bigwigsmods/bigwigs"] == 900)
    }

    @Test func batchedWritesNotifyObservers() async throws {
        let database = try MetadataDatabase.inMemory()
        let cache = SupportCache(database: database)
        let changes = await database.changes()
        await cache.set([
            SupportRecord(ref: bw, status: .supported(version: "1"), checkedAt: Date()),
            SupportRecord(ref: dbm, status: .unsupported, checkedAt: Date()),
        ])
        var iterator = changes.makeAsyncIterator()
        let change = try #require(await iterator.next())
        #expect(change.tables == ["support", "repo_meta"])
        #expect(change.repos == ["bigwigsmods/bigwigs", "deadlybossmods/deadlybossmods"])
    }
}

@Suite struct InstalledSearchTests {
    let statuses: [AddonStatus] = [
        .managed(sampleInstalledAddon("BigWigsMods/BigWigs", name: "BigWigs", folders: ["BigWigs", "BigWigs_Core"]), missingFolders: []),
        .managed(sampleInstalledAddon("funkydude/BugSack", name: "BugSack", folders: ["BugSack"]), missingFolders: []),
        .unmanaged(
            folder: "Baganator",
            toc: Toc(parsing: "## Title: |cff00ff00Baganator|r\n## Notes: Bag replacement\n"),
            suggestedRef: AddonRef(source: .github, identifier: "plusmouse/Baganator")
        ),
        .unmanaged(folder: "MysteryAddon", toc: nil, suggestedRef: nil),
    ]

    @Test func matchesManagedByNameAndCamelCase() {
        let provider = InstalledSearchProvider(addons: statuses)
        let results = provider.search(SearchQuery(text: "wigs"))
        #expect(results.map(\.id.identifier) == ["BigWigsMods/BigWigs"])
        #expect(results[0].origin == [.installed])
        #expect(results[0].installed?.name == "BigWigs")
        #expect(results[0].owner == "BigWigsMods")
    }

    @Test func matchesFoldersAndOwner() {
        let provider = InstalledSearchProvider(addons: statuses)
        #expect(provider.search(SearchQuery(text: "core")).map(\.name) == ["BigWigs"])
        #expect(provider.search(SearchQuery(text: "funky")).map(\.name) == ["BugSack"])
    }

    @Test func matchesUnmanagedTocTitleAndNotes() {
        let provider = InstalledSearchProvider(addons: statuses)
        let results = provider.search(SearchQuery(text: "bag"))
        #expect(results.map(\.name) == ["Baganator"])
        #expect(results[0].installed == nil)
        #expect(results[0].summary == "Bag replacement")
        #expect(provider.search(SearchQuery(text: "replacement")).count == 1)
        #expect(provider.search(SearchQuery(text: "mystery")).isEmpty)
    }

    @Test func emptyQuery() {
        #expect(InstalledSearchProvider(addons: statuses).search(SearchQuery(text: " ")).isEmpty)
    }
}

@Suite struct GitHubSearchProviderTests {
    @Test func buildsEncodedQueryURL() {
        let url = GitHubSearchProvider.url(forQuery: "boss mods in:name,description topic:wow-addon")
        #expect(url.absoluteString == "https://api.github.com/search/repositories?q=boss+mods+in%3Aname%2Cdescription+topic%3Awow-addon&sort=updated&per_page=30")
        let tricky = GitHubSearchProvider.url(forQuery: "a&b=c #d+é")
        #expect(tricky.absoluteString.contains("q=a%26b%3Dc+%23d%2B%C3%A9&"))
    }

    @Test func sendsHeadersAndMapsResults() async throws {
        let http = StubHTTPClient()
        let q1 = GitHubSearchProvider.url(forQuery: "bags in:name,description topic:wow-addon").absoluteString
        http.stub(q1, body: githubSearchBody([
            ("a/One", 5, false, false), ("a/Two", 3, false, false), ("a/Three", 1, false, false),
            ("a/Four", 1, false, false), ("a/Five", 0, false, false),
        ]))
        let provider = GitHubSearchProvider(http: http, token: "secret")
        let results = try await provider.search(SearchQuery(text: "  bags "))
        #expect(results.map(\.id.identifier) == ["a/One", "a/Two", "a/Three", "a/Four", "a/Five"])
        let first = results[0]
        #expect(first.name == "One")
        #expect(first.owner == "a")
        #expect(first.stars == 5)
        #expect(first.summary == "About One")
        #expect(first.lastUpdated == CatalogueCSV.parseDate("2026-09-01T12:00:00Z"))
        #expect(first.origin == [.github])
        #expect(first.support == .unknown)

        #expect(http.requests.count == 1)
        let request = http.requests[0]
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func fallsBackThroughQueriesFilteringAndDeduping() async throws {
        let http = StubHTTPClient()
        let qs = GitHubSearchProvider.queries(for: "bags").map { GitHubSearchProvider.url(forQuery: $0).absoluteString }
        http.stub(qs[0], body: githubSearchBody([("a/One", 1, false, false), ("a/Archived", 1, true, false)]))
        http.stub(qs[1], body: githubSearchBody([("a/one", 1, false, false), ("a/Fork", 1, false, true), ("b/Two", 1, false, false)]))
        http.stub(qs[2], body: githubSearchBody(["c/Three", "c/Four", "c/Five"]))
        let provider = GitHubSearchProvider(http: http)
        let results = try await provider.search(SearchQuery(text: "bags"))
        #expect(results.map(\.id.identifier) == ["a/One", "b/Two", "c/Three", "c/Four", "c/Five"])
        #expect(http.requests.map(\.url?.absoluteString) == qs)
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(qs[2].contains("wow+OR+warcraft"))
        #expect(!qs[2].contains("topic"))
    }

    @Test func cachesPerQueryForTenMinutes() async throws {
        let http = StubHTTPClient()
        let clock = SearchTestClock()
        let qs = GitHubSearchProvider.queries(for: "dbm").map { GitHubSearchProvider.url(forQuery: $0).absoluteString }
        http.stub(qs[0], body: githubSearchBody(["a/1", "a/2", "a/3", "a/4", "a/5"]))
        let provider = GitHubSearchProvider(http: http, now: { clock.now })
        _ = try await provider.search(SearchQuery(text: "dbm"))
        _ = try await provider.search(SearchQuery(text: "dbm "))
        #expect(http.requests.count == 1)
        clock.advance(11 * 60)
        _ = try await provider.search(SearchQuery(text: "dbm"))
        #expect(http.requests.count == 2)
    }

    @Test func rateLimitThrows() async throws {
        let http = StubHTTPClient()
        let q = GitHubSearchProvider.url(forQuery: GitHubSearchProvider.queries(for: "bags")[0]).absoluteString
        http.stub(q, status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000600"], body: Data())
        let provider = GitHubSearchProvider(http: http)
        await #expect(throws: AddonError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_600))) {
            try await provider.search(SearchQuery(text: "bags"))
        }

        let clock = SearchTestClock()
        http.stub(q, status: 429, headers: ["Retry-After": "30"], body: Data())
        let provider2 = GitHubSearchProvider(http: http, now: { clock.now })
        await #expect(throws: AddonError.rateLimited(resetAt: clock.now.addingTimeInterval(30))) {
            try await provider2.search(SearchQuery(text: "bags"))
        }
    }

    @Test func rateLimitAfterPartialResultsReturnsWhatItHas() async throws {
        let http = StubHTTPClient()
        let qs = GitHubSearchProvider.queries(for: "bags").map { GitHubSearchProvider.url(forQuery: $0).absoluteString }
        http.stub(qs[0], body: githubSearchBody(["a/One"]))
        http.stub(qs[1], status: 429, body: Data())
        let provider = GitHubSearchProvider(http: http)
        #expect(try await provider.search(SearchQuery(text: "bags")).map(\.id.identifier) == ["a/One"])
        #expect(http.requests.count == 2)
    }

    @Test func otherErrorsThrowHTTP() async throws {
        let http = StubHTTPClient()
        let q = GitHubSearchProvider.url(forQuery: GitHubSearchProvider.queries(for: "x")[0])
        http.stub(q.absoluteString, status: 422, body: Data())
        await #expect(throws: AddonError.http(status: 422, url: q)) {
            try await GitHubSearchProvider(http: http).search(SearchQuery(text: "x"))
        }
    }
}
