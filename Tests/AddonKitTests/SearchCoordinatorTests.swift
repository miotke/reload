import Foundation
import Testing
@testable import AddonKit

private struct Harness {
    let http = StubHTTPClient()
    let database: MetadataDatabase
    let catalogue: CatalogueSource
    let cache: SupportCache
    let coordinator: SearchCoordinator

    init(withGitHub: Bool = true, liveDelay: Duration = .zero) async throws {
        http.stub(CatalogueSource.defaultURL.absoluteString, body: try fixtureData("search/addons.csv"))
        database = try MetadataDatabase.inMemory()
        catalogue = CatalogueSource(http: http, database: database)
        cache = SupportCache(database: database)
        coordinator = SearchCoordinator(
            catalogue: catalogue,
            github: withGitHub ? GitHubSearchProvider(http: http, database: database) : nil,
            supportCache: cache
        )
        await coordinator.setLiveSearchDelay(liveDelay)
    }

    var githubRequests: [URLRequest] {
        http.requests.filter { $0.url?.host() == "api.github.com" }
    }

    func stubGitHub(_ text: String, stage: Int = 0, status: Int = 200, headers: [String: String] = [:], body: Data) {
        let q = GitHubSearchProvider.queries(for: text)[stage]
        http.stub(GitHubSearchProvider.url(forQuery: q).absoluteString, status: status, headers: headers, body: body)
    }

    func collect(_ query: SearchQuery, installed: [AddonStatus] = []) async -> [[SearchResult]] {
        var emissions: [[SearchResult]] = []
        for await results in coordinator.search(query, installed: installed) {
            emissions.append(results)
        }
        return emissions
    }

    func updates(_ query: SearchQuery) async -> [SearchUpdate] {
        var out: [SearchUpdate] = []
        for await update in coordinator.searchUpdates(query, installed: []) { out.append(update) }
        return out
    }
}

private func ids(_ results: [SearchResult]) -> [String] { results.map(\.id.identifier) }

private let bugsackLive: [(fullName: String, stars: Int, archived: Bool, fork: Bool)] = [
    ("funkydude/BugSack", 120, false, false),
    ("x/BugSackSkin", 3, false, false),
    ("x/Old", 3, true, false),
    ("y/BugSackFork", 1, false, true),
    ("z/BugSackExtras", 2, false, false),
    ("w/BugSackLDB", 1, false, false),
    ("v/BugSackTheme", 1, false, false),
]

@Suite struct SearchCoordinatorTests {
    let bigWigsRef = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs")

    @Test func installedFirstThenCatalogueMergedByRef() async throws {
        let h = try await Harness(withGitHub: false)
        let installed: [AddonStatus] = [
            .managed(sampleInstalledAddon("BigWigsMods/BigWigs", name: "BigWigs", folders: ["BigWigs"]), missingFolders: []),
            .managed(sampleInstalledAddon("someone/WigsHelper", name: "WigsHelper", folders: ["WigsHelper"]), missingFolders: []),
        ]
        let emissions = await h.collect(SearchQuery(text: "bigwigs", flavor: .forever), installed: installed)
        let first = try #require(emissions.first)
        #expect(first.first?.id == bigWigsRef)
        #expect(first.first?.origin == [.installed, .catalogue])
        #expect(first.first?.installed?.name == "BigWigs")
        #expect(first.first?.summary != nil)
        #expect(Set(ids(first)).count == first.count, "results are deduped")
    }

    @Test func catalogueResultsForInstalledAddonsAreMarked() async throws {
        let h = try await Harness(withGitHub: false)
        let installed: [AddonStatus] = [
            .managed(sampleInstalledAddon("funkydude/BugSack", name: "Bug Sack Renamed", folders: ["BugSack"]), missingFolders: []),
        ]
        // The query doesn't match the installed record, but the catalogue hit must still carry `installed`.
        let emissions = await h.collect(SearchQuery(text: "collected errors", flavor: .forever), installed: installed)
        let bugsack = try #require(emissions.first?.first { $0.id.identifier == "funkydude/BugSack" })
        #expect(bugsack.installed != nil)
        #expect(bugsack.origin.contains(.installed))
    }

    @Test func searchIsLocalOnceTheCatalogueIsStored() async throws {
        let h = try await Harness()
        _ = await h.collect(SearchQuery(text: "bigwigs", flavor: .forever))
        #expect(h.http.requests.count == 1, "only the first-ever catalogue download")
        let emissions = await h.collect(SearchQuery(text: "bigwigs", flavor: .forever))
        #expect(emissions.count == 1)
        #expect(h.http.requests.count == 1)
        #expect(emissions[0].allSatisfy { $0.support != .checking })
    }

    @Test func storedVerdictsAreApplied() async throws {
        let h = try await Harness(withGitHub: false)
        await h.cache.set(.supported(version: "v1"), for: bigWigsRef, flavor: .forever)
        let first = try #require(await h.collect(SearchQuery(text: "bigwigs", flavor: .forever)).first)
        #expect(first.first { $0.id == bigWigsRef }?.support == .supported(version: "v1"))
    }

    @Test func catalogueRowsWithoutReleaseJSONNeedADownload() async throws {
        let h = try await Harness(withGitHub: false)
        let entries = try await h.catalogue.entries()
        let without = try #require(entries.first { !$0.hasReleaseJSON })
        let with = try #require(entries.first { $0.hasReleaseJSON })
        let results = try #require(await h.collect(SearchQuery(text: without.fullName, flavor: .forever, hideIncompatible: false)).first)
        #expect(results.first { $0.id == without.ref }?.support == .needsDownload)
        let others = try #require(await h.collect(SearchQuery(text: with.fullName, flavor: .forever, hideIncompatible: false)).first)
        #expect(others.first { $0.id == with.ref }?.support == .unknown)
    }

    @Test func storedSupportBreaksTiesInRanking() async throws {
        let h = try await Harness(withGitHub: false)
        let classic = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs_Classic")
        await h.cache.set(.supported(version: "v1"), for: classic, flavor: .forever)
        let first = try #require(await h.collect(SearchQuery(text: "bigwigs", flavor: .forever)).first)
        // BigWigs is the exact-name tier; among prefix matches the supported one leads.
        #expect(Array(ids(first).prefix(2)) == ["BigWigsMods/BigWigs", "BigWigsMods/BigWigs_Classic"])
    }

    /// BigWigs_Classic ships classic builds only, BigWigs a Retail build only.
    private func storeFamilies(_ h: Harness) async {
        let now = Date()
        await h.cache.set([SupportRecord(ref: AddonRef(source: .github, identifier: "BigWigsMods/BigWigs_Classic"), status: .unsupported,
                                         tag: "v1", checkedAt: now, availableFlavors: [.vanilla, .mists])], flavor: .forever)
        await h.cache.set([SupportRecord(ref: bigWigsRef, status: .unsupported, tag: "v1", checkedAt: now, availableFlavors: [.mainline])], flavor: .forever)
        await h.cache.set(.noReleases, for: AddonRef(source: .github, identifier: "BigWigsMods/BigWigs_Legion"), flavor: .forever)
        await h.cache.set(.needsDownload, for: AddonRef(source: .github, identifier: "BigWigsMods/BigWigs_Voice"), flavor: .forever)
    }

    @Test func hideIncompatibleOnForeverHidesClassicOnly() async throws {
        let h = try await Harness(withGitHub: false)
        await storeFamilies(h)
        let shown = try #require(await h.collect(SearchQuery(text: "bigwigs", flavor: .forever, hideIncompatible: true)).last)
        #expect(!ids(shown).contains("BigWigsMods/BigWigs_Classic"))
        #expect(!ids(shown).contains("BigWigsMods/BigWigs_Legion"))
        #expect(ids(shown).contains("BigWigsMods/BigWigs_Voice"), "unknown families stay")
        #expect(ids(shown).contains("BigWigsMods/BigWigs"), "a Retail-only build may work on Forever")
        #expect(shown.first { $0.id == bigWigsRef }?.families == [.retail])

        let all = try #require(await h.collect(SearchQuery(text: "bigwigs", flavor: .forever, hideIncompatible: false)).last)
        #expect(all.first { $0.id.identifier == "BigWigsMods/BigWigs_Classic" }?.families == [.classic])
        #expect(all.first { $0.id.identifier == "BigWigsMods/BigWigs_Legion" }?.support == .noReleases)
        #expect(all.first { $0.id.identifier == "BigWigsMods/BigWigs_Voice" }?.availableFlavors == nil)
    }

    @Test func hideIncompatibleFollowsTheInstallationsFamily() async throws {
        let h = try await Harness(withGitHub: false)
        await storeFamilies(h)
        let retail = try #require(await h.collect(SearchQuery(text: "bigwigs", flavor: .mainline)).last)
        #expect(!ids(retail).contains("BigWigsMods/BigWigs_Classic"))
        #expect(ids(retail).contains("BigWigsMods/BigWigs"))
        let mists = try #require(await h.collect(SearchQuery(text: "bigwigs", flavor: .mists)).last)
        #expect(ids(mists).contains("BigWigsMods/BigWigs_Classic"))
        #expect(!ids(mists).contains("BigWigsMods/BigWigs"))
        #expect(ids(mists).contains("BigWigsMods/BigWigs_Voice"))
    }

    @Test func hideIncompatibleKeepsInstalledEvenIfUnsupported() async throws {
        let h = try await Harness(withGitHub: false)
        await h.cache.set(.unsupported, for: bigWigsRef, flavor: .forever)
        let installed: [AddonStatus] = [
            .managed(sampleInstalledAddon("BigWigsMods/BigWigs", name: "BigWigs", folders: ["BigWigs"]), missingFolders: []),
        ]
        await h.cache.setAvailableFlavors([.vanilla], tag: "v1", source: .releaseJSON, for: bigWigsRef)
        let first = try #require(await h.collect(SearchQuery(text: "bigwigs", flavor: .forever), installed: installed).first)
        #expect(first.first?.id == bigWigsRef)
    }

    @Test func directReferenceComesFirstAndMergesWithCatalogue() async throws {
        let h = try await Harness()
        let first = try #require(await h.collect(SearchQuery(text: "https://github.com/BigWigsMods/BigWigs", flavor: .forever)).first)
        let top = try #require(first.first)
        #expect(top.id == bigWigsRef)
        #expect(top.origin.isSuperset(of: [.direct, .catalogue]))
        #expect(top.name == "BigWigs")
        #expect(top.summary != nil)
        #expect(h.githubRequests.isEmpty, "direct references don't trigger live search")
    }

    @Test func unknownDirectReferenceStaysUnknown() async throws {
        let h = try await Harness()
        let emissions = await h.collect(SearchQuery(text: "someone/BrandNewAddon", flavor: .forever))
        #expect(emissions.count == 1)
        #expect(ids(emissions[0]) == ["someone/BrandNewAddon"])
        #expect(emissions[0][0].origin == [.direct])
        #expect(emissions[0][0].support == .unknown)
        #expect(h.githubRequests.isEmpty)
    }

    @Test func fewLocalMatchesAskGitHubOnceAndRemember() async throws {
        let h = try await Harness()
        h.stubGitHub("bugsack", body: githubSearchBody(bugsackLive))
        let emissions = await h.collect(SearchQuery(text: "bugsack", flavor: .forever))
        #expect(ids(try #require(emissions.first)) == ["funkydude/BugSack"])

        let last = try #require(emissions.last)
        #expect(ids(last) == ["funkydude/BugSack", "x/BugSackSkin", "z/BugSackExtras", "w/BugSackLDB", "v/BugSackTheme"])
        #expect(last[0].origin == [.catalogue, .github])
        #expect(last[0].stars == 120)
        #expect(last.dropFirst().allSatisfy { $0.support == .unknown })
        // The automatic fallback is a single request (no topic fallbacks).
        #expect(h.githubRequests.count == 1)

        // The live repos are now in the local catalogue: no request the second time.
        let again = try #require(await h.collect(SearchQuery(text: "BugSack ", flavor: .forever)).last)
        #expect(Set(ids(again)).isSuperset(of: ["x/BugSackSkin", "v/BugSackTheme"]))
        #expect(h.githubRequests.count == 1)
    }

    @Test func emptyLiveAnswersAreRemembered() async throws {
        let h = try await Harness()
        h.stubGitHub("zzqx", body: githubSearchBody([String]()))
        _ = await h.collect(SearchQuery(text: "zzqx", flavor: .forever))
        _ = await h.collect(SearchQuery(text: "ZZQX", flavor: .forever))
        #expect(h.githubRequests.count == 1)
    }

    @Test func shortQueriesNeverFallBack() async throws {
        let h = try await Harness()
        _ = await h.collect(SearchQuery(text: "zq", flavor: .forever))
        #expect(h.githubRequests.isEmpty)
    }

    @Test func updatesReportTheGitHubFallback() async throws {
        let h = try await Harness()
        h.stubGitHub("bugsack", body: githubSearchBody(bugsackLive))
        let updates = await h.updates(SearchQuery(text: "bugsack", flavor: .forever))
        #expect(updates.map(\.isSearchingGitHub) == [false, true, false])
        #expect(updates.map(\.isComplete) == [false, false, true])
        #expect(updates.last?.results.count == 5)

        let local = await h.updates(SearchQuery(text: "bigwigs", flavor: .forever))
        #expect(local.count == 1)
        #expect(local[0].isComplete && !local[0].isSearchingGitHub)
    }

    /// A remembered live answer is read before the settle delay, and isn't shown as a
    /// GitHub search.
    @Test func aStoredLiveAnswerSkipsTheDelay() async throws {
        let h = try await Harness()
        h.stubGitHub("bugsack", body: githubSearchBody(bugsackLive))
        _ = await h.updates(SearchQuery(text: "bugsack", flavor: .forever))
        await h.coordinator.setLiveSearchDelay(.seconds(30))
        let clock = ContinuousClock()
        let start = clock.now
        let updates = await h.updates(SearchQuery(text: "bugsack", flavor: .forever))
        #expect(clock.now - start < .seconds(5), "no 30 s delay")
        #expect(updates.allSatisfy { !$0.isSearchingGitHub })
        #expect(updates.last?.isComplete == true)
        #expect(updates.last?.results.count == 5)
        #expect(h.githubRequests.count == 1)
    }

    @Test func cancellingDuringTheDelaySkipsGitHub() async throws {
        let h = try await Harness(liveDelay: .seconds(30))
        h.stubGitHub("bugsack", body: githubSearchBody(bugsackLive))
        let coordinator = h.coordinator
        let consumer = Task {
            for await _ in coordinator.search(SearchQuery(text: "bugsack", flavor: .forever), installed: []) { break }
        }
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.githubRequests.isEmpty)
    }

    @Test func manyLocalMatchesSkipGitHubUnlessAsked() async throws {
        let h = try await Harness()
        _ = await h.collect(SearchQuery(text: "bigwigs", flavor: .forever))
        #expect(h.githubRequests.isEmpty)

        h.stubGitHub("bigwigs", body: githubSearchBody(["BigWigsMods/BigWigs", "a/1", "a/2", "a/3", "a/4"]))
        let last = try #require(await h.collect(SearchQuery(text: "bigwigs", flavor: .forever, includeLiveGitHub: true)).last)
        #expect(h.githubRequests.count == 1)
        #expect(last.filter { $0.id == bigWigsRef }.count == 1)
        #expect(ids(last).contains("a/4"))
    }

    @Test func rateLimitIsQuietSharedAndRespected() async throws {
        let h = try await Harness()
        h.stubGitHub("bugsack", status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(Int(Date().timeIntervalSince1970) + 600)"], body: Data())
        let emissions = await h.collect(SearchQuery(text: "bugsack", flavor: .forever))
        #expect(ids(try #require(emissions.last)) == ["funkydude/BugSack"])
        #expect(h.githubRequests.count == 1)
        #expect(await h.database.rateLimit("search")?.remaining == 0)

        // Until the reset, other queries don't even try.
        _ = await h.collect(SearchQuery(text: "qqzzqq", flavor: .forever))
        #expect(h.githubRequests.count == 1)
    }

    @Test func emptyQueryEmitsNothing() async throws {
        let h = try await Harness()
        let emissions = await h.collect(SearchQuery(text: "   ", flavor: .forever))
        #expect(emissions == [[]])
        #expect(h.http.requests.isEmpty)
    }

    @Test func catalogueFailureStillSearchesInstalled() async throws {
        let database = try MetadataDatabase.inMemory()
        let coordinator = SearchCoordinator(
            catalogue: CatalogueSource(http: StubHTTPClient(), database: database), github: nil,
            supportCache: SupportCache(database: database)
        )
        let installed: [AddonStatus] = [
            .managed(sampleInstalledAddon("BigWigsMods/BigWigs", name: "BigWigs", folders: ["BigWigs"]), missingFolders: []),
        ]
        var last: [SearchResult] = []
        for await results in coordinator.search(SearchQuery(text: "wigs", flavor: .forever), installed: installed) { last = results }
        #expect(ids(last) == ["BigWigsMods/BigWigs"])
    }

    @Test func browse() async throws {
        let h = try await Harness()
        _ = try await h.catalogue.entries()
        await h.cache.set(.supported(version: "1"), for: bigWigsRef, flavor: .forever)
        await h.cache.set(.supported(version: "2"), for: AddonRef(source: .github, identifier: "funkydude/BugSack"), flavor: .forever)
        // Classic-only, so hidden on Forever; an unsupported verdict alone no longer hides a row.
        await h.cache.set([SupportRecord(ref: AddonRef(source: .github, identifier: "Cidan/BetterBags"), status: .unsupported,
                                         tag: "v1", checkedAt: Date(), availableFlavors: [.vanilla])], flavor: .forever)
        let browse = await h.coordinator.browse(flavor: .forever)

        #expect(Set(ids(browse.popular)) == ["BigWigsMods/BigWigs", "funkydude/BugSack"])
        #expect(browse.popular.allSatisfy { if case .supported = $0.support { true } else { false } })
        // No star data yet: newest first. BugSack (2026-09-18) is newer than BigWigs (2026-09-12).
        #expect(ids(browse.popular) == ["funkydude/BugSack", "BigWigsMods/BigWigs"])

        #expect(browse.recent.count == 20)
        let dates = browse.recent.compactMap(\.lastUpdated)
        #expect(dates == dates.sorted(by: >))
        #expect(!ids(browse.recent).contains("Cidan/BetterBags"))
        #expect(h.githubRequests.isEmpty)

        #expect(browse.categories.map(\.title) == ["Boss mods", "Bags", "UI", "Quests", "Maps", "Auction", "Combat"])
    }

    @Test func browseSortsPopularByStarsOnceKnown() async throws {
        let h = try await Harness()
        h.stubGitHub("zzqx", body: githubSearchBody([("BigWigsMods/BigWigs", 900, false, false), ("funkydude/BugSack", 50, false, false)]))
        _ = await h.collect(SearchQuery(text: "zzqx", flavor: .forever))
        await h.cache.set(.supported(version: "1"), for: bigWigsRef, flavor: .forever)
        await h.cache.set(.supported(version: "2"), for: AddonRef(source: .github, identifier: "funkydude/BugSack"), flavor: .forever)
        let popular = await h.coordinator.browse(flavor: .forever).popular
        #expect(ids(popular) == ["BigWigsMods/BigWigs", "funkydude/BugSack"])
        #expect(popular.first?.stars == 900)
    }
}

@Suite struct DirectReferenceTests {
    @Test(arguments: [
        ("BigWigsMods/BigWigs", "BigWigsMods/BigWigs"),
        ("  funkydude/BugSack ", "funkydude/BugSack"),
        ("https://github.com/funkydude/BugSack", "funkydude/BugSack"),
        ("https://github.com/funkydude/BugSack.git", "funkydude/BugSack"),
        ("https://github.com/funkydude/BugSack/releases/tag/v1", "funkydude/BugSack"),
        ("github.com/a-b/c.d_e", "a-b/c.d_e"),
        ("http://www.github.com/Owner/Repo/", "Owner/Repo"),
    ])
    func parses(input: String, expected: String) {
        #expect(SearchCoordinator.directReference(input) == AddonRef(source: .github, identifier: expected))
    }

    @Test(arguments: ["bigwigs", "boss mods", "a/b/c", "/repo", "owner/", "https://gitlab.com/a/b", "https://github.com/onlyowner", "own er/repo", "-bad/repo"])
    func rejects(input: String) {
        #expect(SearchCoordinator.directReference(input) == nil)
    }
}
