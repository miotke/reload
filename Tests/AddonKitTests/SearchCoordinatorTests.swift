import Foundation
import Testing
@testable import AddonKit

/// Scripted `SupportChecking` that records calls and peak concurrency.
final class MockSupportChecker: SupportChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: SupportStatus]
    private let fallback: SupportStatus
    private let delay: Duration
    private var _calls: [AddonRef] = []
    private var _current = 0
    private var _peak = 0
    private var _cancelled = 0

    init(_ statuses: [String: SupportStatus] = [:], fallback: SupportStatus = .needsDownload, delay: Duration = .milliseconds(5)) {
        self.statuses = statuses
        self.fallback = fallback
        self.delay = delay
    }

    var calls: [AddonRef] { lock.withLock { _calls } }
    var peakConcurrency: Int { lock.withLock { _peak } }
    var cancelledCount: Int { lock.withLock { _cancelled } }

    func support(for ref: AddonRef, flavor: Flavor) async -> SupportStatus {
        lock.withLock {
            _calls.append(ref)
            _current += 1
            _peak = max(_peak, _current)
        }
        let cancelled: Bool
        do {
            try await Task.sleep(for: delay)
            cancelled = false
        } catch {
            cancelled = true
        }
        return lock.withLock {
            _current -= 1
            if cancelled { _cancelled += 1; return .unknown }
            return statuses[ref.identifier] ?? fallback
        }
    }
}

private struct Harness {
    let http = StubHTTPClient()
    let checker: MockSupportChecker
    let cache: SupportCache
    let coordinator: SearchCoordinator

    init(checker: MockSupportChecker = MockSupportChecker(), withGitHub: Bool = true) throws {
        let dir = try makeTempDirectory()
        http.stub(CatalogueSource.defaultURL.absoluteString, body: try fixtureData("search/addons.csv"))
        self.checker = checker
        cache = SupportCache(directory: dir)
        coordinator = SearchCoordinator(
            catalogue: CatalogueSource(http: http, cacheDirectory: dir),
            github: withGitHub ? GitHubSearchProvider(http: http) : nil,
            support: checker,
            supportCache: cache
        )
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
}

private func ids(_ results: [SearchResult]) -> [String] { results.map(\.id.identifier) }

@Suite struct SearchCoordinatorTests {
    let bigWigsRef = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs")

    @Test func installedFirstThenCatalogueMergedByRef() async throws {
        let h = try Harness(withGitHub: false)
        let installed: [AddonStatus] = [
            .managed(sampleInstalledAddon("BigWigsMods/BigWigs", name: "BigWigs", folders: ["BigWigs"]), missingFolders: []),
            .managed(sampleInstalledAddon("someone/WigsHelper", name: "WigsHelper", folders: ["WigsHelper"]), missingFolders: []),
        ]
        let emissions = await h.collect(SearchQuery(text: "bigwigs"), installed: installed)
        let first = try #require(emissions.first)
        #expect(first.first?.id == bigWigsRef)
        #expect(first.first?.origin == [.installed, .catalogue])
        #expect(first.first?.installed?.name == "BigWigs")
        #expect(first.first?.summary != nil)
        #expect(Set(ids(first)).count == first.count, "results are deduped")
        #expect(first.filter { $0.id == bigWigsRef }.count == 1)
    }

    @Test func catalogueResultsForInstalledAddonsAreMarked() async throws {
        let h = try Harness(withGitHub: false)
        let installed: [AddonStatus] = [
            .managed(sampleInstalledAddon("funkydude/BugSack", name: "Bug Sack Renamed", folders: ["BugSack"]), missingFolders: []),
        ]
        // The query doesn't match the installed record, but the catalogue hit must still carry `installed`.
        let emissions = await h.collect(SearchQuery(text: "collected errors"), installed: installed)
        let bugsack = try #require(emissions.first?.first { $0.id.identifier == "funkydude/BugSack" })
        #expect(bugsack.installed != nil)
        #expect(bugsack.origin.contains(.installed))
    }

    @Test func verifiesTopResultsWithAtMostTwoConcurrentChecks() async throws {
        let checker = MockSupportChecker(["BigWigsMods/BigWigs": .supported(version: "v400")], delay: .milliseconds(10))
        let h = try Harness(checker: checker, withGitHub: false)
        let emissions = await h.collect(SearchQuery(text: "bigwigs"))
        let first = try #require(emissions.first)
        #expect(first.count > SearchCoordinator.verificationLimit)
        #expect(first.prefix(SearchCoordinator.verificationLimit).allSatisfy { $0.support == .checking })
        #expect(first.dropFirst(SearchCoordinator.verificationLimit).allSatisfy { $0.support == .unknown })

        #expect(checker.calls.count == SearchCoordinator.verificationLimit)
        #expect(checker.peakConcurrency == 2)
        // One emission up front plus one per landed check.
        #expect(emissions.count == 1 + SearchCoordinator.verificationLimit)
        let last = try #require(emissions.last)
        #expect(last.first?.support == .supported(version: "v400"))
        #expect(last.prefix(SearchCoordinator.verificationLimit).allSatisfy { $0.support != .checking })

        // Verdicts are stored.
        #expect(await h.cache.status(for: bigWigsRef) == .supported(version: "v400"))
    }

    @Test func cachedStatusesAreAppliedAndNotRechecked() async throws {
        let h = try Harness(withGitHub: false)
        await h.cache.set(.supported(version: "v1"), for: bigWigsRef)
        let emissions = await h.collect(SearchQuery(text: "bigwigs"))
        #expect(emissions.first?.first { $0.id == bigWigsRef }?.support == .supported(version: "v1"))
        #expect(!h.checker.calls.contains(bigWigsRef))
    }

    @Test func cachedSupportBreaksTiesInRanking() async throws {
        let h = try Harness(withGitHub: false)
        let classic = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs_Classic")
        await h.cache.set(.supported(version: "v1"), for: classic)
        let first = try #require(await h.collect(SearchQuery(text: "bigwigs")).first)
        // BigWigs is the exact-name tier; among prefix matches the supported one leads.
        #expect(Array(ids(first).prefix(2)) == ["BigWigsMods/BigWigs", "BigWigsMods/BigWigs_Classic"])
    }

    @Test func foreverOnlyHidesVerifiedUnsupported() async throws {
        let statuses: [String: SupportStatus] = [
            "BigWigsMods/BigWigs_Classic": .unsupported,
            "BigWigsMods/BigWigs_Legion": .noReleases,
            "BigWigsMods/BigWigs_Voice": .needsDownload,
        ]
        let on = try Harness(checker: MockSupportChecker(statuses, fallback: .unknown), withGitHub: false)
        let shown = try #require(await on.collect(SearchQuery(text: "bigwigs", foreverOnly: true)).last)
        #expect(!ids(shown).contains("BigWigsMods/BigWigs_Classic"))
        #expect(!ids(shown).contains("BigWigsMods/BigWigs_Legion"))
        #expect(ids(shown).contains("BigWigsMods/BigWigs_Voice"))
        #expect(ids(shown).contains("BigWigsMods/BigWigs"))

        let off = try Harness(checker: MockSupportChecker(statuses, fallback: .unknown), withGitHub: false)
        let all = try #require(await off.collect(SearchQuery(text: "bigwigs", foreverOnly: false)).last)
        #expect(ids(all).contains("BigWigsMods/BigWigs_Classic"))
        #expect(all.first { $0.id.identifier == "BigWigsMods/BigWigs_Legion" }?.support == .noReleases)
    }

    @Test func foreverOnlyKeepsInstalledEvenIfUnsupported() async throws {
        let h = try Harness(withGitHub: false)
        await h.cache.set(.unsupported, for: bigWigsRef)
        let installed: [AddonStatus] = [
            .managed(sampleInstalledAddon("BigWigsMods/BigWigs", name: "BigWigs", folders: ["BigWigs"]), missingFolders: []),
        ]
        let first = try #require(await h.collect(SearchQuery(text: "bigwigs"), installed: installed).first)
        #expect(first.first?.id == bigWigsRef)
    }

    @Test func directReferenceComesFirstAndMergesWithCatalogue() async throws {
        let h = try Harness()
        let first = try #require(await h.collect(SearchQuery(text: "https://github.com/BigWigsMods/BigWigs")).first)
        let top = try #require(first.first)
        #expect(top.id == bigWigsRef)
        #expect(top.origin.isSuperset(of: [.direct, .catalogue]))
        #expect(top.name == "BigWigs")
        #expect(top.summary != nil)
        #expect(h.githubRequests.isEmpty, "direct references don't trigger live search")
    }

    @Test func unknownDirectReferenceStillProducesAResult() async throws {
        let h = try Harness(checker: MockSupportChecker(fallback: .supported(version: "1.0")))
        let emissions = await h.collect(SearchQuery(text: "someone/BrandNewAddon"))
        let first = try #require(emissions.first)
        #expect(ids(first) == ["someone/BrandNewAddon"])
        #expect(first[0].origin == [.direct])
        #expect(first[0].owner == "someone")
        #expect(first[0].support == .checking)
        #expect(emissions.last?.first?.support == .supported(version: "1.0"))
    }

    @Test func fewCatalogueMatchesTriggerGitHubLiveSearch() async throws {
        let h = try Harness()
        h.stubGitHub("bugsack", body: githubSearchBody([
            ("funkydude/BugSack", 120, false, false),
            ("x/BugSackSkin", 3, false, false),
            ("x/Old", 3, true, false),
            ("y/BugSackFork", 1, false, true),
            ("z/BugSackExtras", 2, false, false),
            ("w/BugSackLDB", 1, false, false),
            ("v/BugSackTheme", 1, false, false),
        ]))
        let emissions = await h.collect(SearchQuery(text: "bugsack"))
        let first = try #require(emissions.first)
        #expect(ids(first) == ["funkydude/BugSack"])

        let last = try #require(emissions.last)
        #expect(ids(last) == ["funkydude/BugSack", "x/BugSackSkin", "z/BugSackExtras", "w/BugSackLDB", "v/BugSackTheme"])
        let bugsack = last[0]
        #expect(bugsack.origin == [.catalogue, .github])
        #expect(bugsack.stars == 120)
        #expect(h.githubRequests.count == 1)
        // Live results get verified too.
        #expect(Set(h.checker.calls.map(\.identifier)) == Set(ids(last)))
    }

    @Test func manyCatalogueMatchesSkipGitHubUnlessAsked() async throws {
        let h = try Harness()
        _ = await h.collect(SearchQuery(text: "bigwigs"))
        #expect(h.githubRequests.isEmpty)

        h.stubGitHub("bigwigs", body: githubSearchBody(["BigWigsMods/BigWigs", "a/1", "a/2", "a/3", "a/4"]))
        let last = try #require(await h.collect(SearchQuery(text: "bigwigs", includeLiveGitHub: true)).last)
        #expect(h.githubRequests.count == 1)
        #expect(last.filter { $0.id == bigWigsRef }.count == 1)
        #expect(ids(last).contains("a/4"))
    }

    @Test func gitHubRateLimitDoesNotFailTheStream() async throws {
        let h = try Harness()
        h.stubGitHub("bugsack", status: 403, headers: ["X-RateLimit-Remaining": "0"], body: Data())
        let emissions = await h.collect(SearchQuery(text: "bugsack"))
        #expect(ids(try #require(emissions.last)) == ["funkydude/BugSack"])
        #expect(h.githubRequests.count == 1)
    }

    @Test func cancellingTheConsumerCancelsChecks() async throws {
        let checker = MockSupportChecker(delay: .seconds(30))
        let h = try Harness(checker: checker, withGitHub: false)
        let coordinator = h.coordinator
        let consumer = Task {
            for await _ in coordinator.search(SearchQuery(text: "bigwigs"), installed: []) {}
        }
        var deadline = ContinuousClock.now + .seconds(5)
        while checker.calls.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        consumer.cancel()

        deadline = ContinuousClock.now + .seconds(5)
        while checker.cancelledCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(checker.cancelledCount == 2)
        #expect(checker.calls.count == 2)
        #expect(await h.cache.statuses().isEmpty)
    }

    @Test func emptyQueryEmitsNothing() async throws {
        let h = try Harness()
        let emissions = await h.collect(SearchQuery(text: "   "))
        #expect(emissions == [[]])
        #expect(h.http.requests.isEmpty)
    }

    @Test func catalogueFailureStillSearchesInstalled() async throws {
        let dir = try makeTempDirectory()
        let http = StubHTTPClient()   // catalogue 404s
        let coordinator = SearchCoordinator(
            catalogue: CatalogueSource(http: http, cacheDirectory: dir), github: nil,
            support: MockSupportChecker(), supportCache: SupportCache(directory: dir)
        )
        let installed: [AddonStatus] = [
            .managed(sampleInstalledAddon("BigWigsMods/BigWigs", name: "BigWigs", folders: ["BigWigs"]), missingFolders: []),
        ]
        var last: [SearchResult] = []
        for await results in coordinator.search(SearchQuery(text: "wigs"), installed: installed) { last = results }
        #expect(ids(last) == ["BigWigsMods/BigWigs"])
    }

    @Test func browse() async throws {
        let h = try Harness()
        await h.cache.set(.supported(version: "1"), for: bigWigsRef)
        await h.cache.set(.supported(version: "2"), for: AddonRef(source: .github, identifier: "funkydude/BugSack"))
        await h.cache.set(.unsupported, for: AddonRef(source: .github, identifier: "Cidan/BetterBags"))
        let browse = await h.coordinator.browse()

        #expect(Set(ids(browse.popular)) == ["BigWigsMods/BigWigs", "funkydude/BugSack"])
        #expect(browse.popular.allSatisfy { if case .supported = $0.support { true } else { false } })
        // No star data yet: newest first. BugSack (2026-09-18) is newer than BigWigs (2026-09-12).
        #expect(ids(browse.popular) == ["funkydude/BugSack", "BigWigsMods/BigWigs"])

        #expect(browse.recent.count == 20)
        let dates = browse.recent.compactMap(\.lastUpdated)
        #expect(dates == dates.sorted(by: >))
        #expect(!ids(browse.recent).contains("Cidan/BetterBags"))

        #expect(browse.categories.map(\.title) == ["Boss mods", "Bags", "UI", "Quests", "Maps", "Auction", "Combat"])
    }

    @Test func browseSortsPopularByStarsOnceKnown() async throws {
        let h = try Harness()
        h.stubGitHub("zzqx", body: githubSearchBody([("BigWigsMods/BigWigs", 900, false, false), ("funkydude/BugSack", 50, false, false)]))
        _ = await h.collect(SearchQuery(text: "zzqx"))
        await h.cache.set(.supported(version: "1"), for: bigWigsRef)
        await h.cache.set(.supported(version: "2"), for: AddonRef(source: .github, identifier: "funkydude/BugSack"))
        let popular = await h.coordinator.browse().popular
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
