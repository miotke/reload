import Foundation
import Testing
@testable import AddonKit

/// Request counts per user action (docs/network/budget.md), offline over stubs.
@Suite struct NetworkBudgetTests {
    func refresh(_ manager: AddonManager, _ installation: Installation, force: Bool = false) async {
        for await _ in manager.refresh(in: installation, force: force) {}
    }

    func heads(_ h: ManagerHarness) -> Int {
        h.http.requests.filter { $0.httpMethod == "HEAD" }.count
    }

    func releaseJSONs(_ h: ManagerHarness) -> Int {
        h.http.urls.filter { $0.hasPrefix("https://github.com/") && $0.hasSuffix("/release.json") }.count
    }

    /// 20 installed add-ons with release.json, as in the audit; they're the catalogue too.
    func installTwenty(_ h: ManagerHarness) async throws {
        let repos = (0..<20).map { "Owner\($0)/Addon\($0)" }
        h.http.stub(CatalogueSource.defaultURL.absoluteString, text: catalogueCSV(repos.map { ($0, $0, "2026-09-01T00:00:00Z", true) }))
        for (i, repo) in repos.enumerated() {
            try h.publish(repo, [("v1", Int64(i + 1), 1)])
            try await h.manager.install(AddonRef(source: .github, identifier: repo), into: h.installation)
        }
        await refresh(h.manager, h.installation)
    }

    @Test func repeatLaunchesFetchNoReleaseJSONAgain() async throws {
        let h = try await ManagerHarness()
        try await installTwenty(h)

        // A launch within 2 hours: nothing.
        h.http.reset()
        await refresh(await h.reopen(), h.installation)
        #expect(h.http.requests.isEmpty)

        // A launch after 2 hours: one HEAD per add-on; tags are unchanged, so no release.json.
        let later = await h.reopen()
        await later.setClock { Date().addingTimeInterval(2 * 3600 + 60) }
        h.http.reset()
        await refresh(later, h.installation)
        #expect(h.http.apiRequests.isEmpty)
        #expect(releaseJSONs(h) == 0)
        #expect(heads(h) == 20)
        #expect(h.http.requests.count == 20)

        // ⌘R in a new process: the same HEADs plus the catalogue revalidation.
        h.http.reset()
        await refresh(await h.reopen(), h.installation, force: true)
        #expect(h.http.apiRequests.isEmpty)
        #expect(releaseJSONs(h) == 0)
        #expect(h.http.requests.count == 21)
    }

    @Test func aNewTagFetchesItsReleaseJSONOnce() async throws {
        let h = try await ManagerHarness()
        let ref = AddonRef(source: .github, identifier: "Test/Addon")
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(ref, into: h.installation)
        try h.publish("Test/Addon", [("v2", 2, 2), ("v1", 1, 1)])

        h.http.reset()
        guard case .available? = try await h.manager.checkForUpdates(in: h.installation)[ref] else {
            Issue.record("expected an update")
            return
        }
        #expect(releaseJSONs(h) == 1)
        // Another process asking again reuses the stored release.json for v2.
        h.http.reset()
        guard case .available? = try await (await h.reopen()).checkForUpdates(in: h.installation)[ref] else {
            Issue.record("expected an update")
            return
        }
        #expect(releaseJSONs(h) == 0)
        #expect(h.http.urls == ["https://github.com/Test/Addon/releases/latest"])
    }

    /// Tags don't depend on the flavor: a second installation's first refresh reuses the
    /// first one's, and the release.json stored for each tag.
    @Test func aSecondFlavorsSeedReusesTagsAndReleaseJSON() async throws {
        let h = try await ManagerHarness()
        let repos = (0..<10).map { "Owner\($0)/Repo\($0)" }
        h.http.stub(CatalogueSource.defaultURL.absoluteString, text: catalogueCSV(repos.map { ($0, $0, "2026-09-01T00:00:00Z", true) }))
        for (i, repo) in repos.enumerated() {
            h.http.publishLatest(repo, tag: "v\(i)", flavors: i.isMultiple(of: 2) ? ["forever", "mainline"] : ["forever"])
        }
        await refresh(h.manager, h.installation)
        #expect(heads(h) == 10)
        #expect(releaseJSONs(h) == 10)

        let retailRoot = h.root.appending(path: "World of Warcraft/_retail_", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: retailRoot.appending(path: "Interface/AddOns"), withIntermediateDirectories: true)
        let retail = try await h.manager.addInstallation(at: retailRoot)
        #expect(retail.flavor == .mainline)

        h.http.reset()
        await refresh(h.manager, retail)
        #expect(h.http.requests.isEmpty, "every tag is under an hour old and its release.json is stored")
        let cache = SupportCache(database: h.manager.database)
        #expect(await cache.status(for: AddonRef(source: .github, identifier: repos[0]), flavor: .mainline) == .supported(version: "v0"))
        #expect(await cache.status(for: AddonRef(source: .github, identifier: repos[1]), flavor: .mainline) == .unsupported)

        // Later, with tags past the hour: HEADs only, release.json still comes from the store.
        let classicRoot = h.root.appending(path: "World of Warcraft/_classic_era_", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: classicRoot.appending(path: "Interface/AddOns"), withIntermediateDirectories: true)
        let classic = try await h.manager.addInstallation(at: classicRoot)
        await h.manager.setClock { Date().addingTimeInterval(2 * 3600) }
        h.http.reset()
        await refresh(h.manager, classic)
        #expect(heads(h) == 10)
        #expect(releaseJSONs(h) == 0)
    }

    @Test func laterInstallationsSeedFewerRepos() async throws {
        let h = try await ManagerHarness()
        let repos = (0..<150).map { "O/R\($0)" }
        h.http.stub(CatalogueSource.defaultURL.absoluteString, text: catalogueCSV(repos.map { ($0, $0, "2026-09-01T00:00:00Z", true) }))
        _ = try await h.manager.catalogue.refresh(force: true)
        let first = await h.manager.supportTargets(installation: h.installation, installed: [], diff: CatalogueDiff(), seed: true)
        #expect(first.count == 150)
        _ = try await h.manager.database.execute(
            "INSERT INTO refresh_state(installation_id, last_refresh_at) VALUES ('other', ?)", Date())
        let later = await h.manager.supportTargets(installation: h.installation, installed: [], diff: CatalogueDiff(), seed: true)
        #expect(later.count == AddonManager.laterSeedCount)
    }

    /// Bulk checks (⌘R, `outdated`, Update All) ask the API about an add-on only it can
    /// decide at most every 6 hours, unless the free latest tag changed. One add-on's own
    /// update always asks.
    @Test func bulkChecksThrottleTheAPI() async throws {
        let h = try await ManagerHarness()
        let ref = AddonRef(source: .github, identifier: "Test/Addon")
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(ref, into: h.installation)
        // The latest release lacks Forever, so only the API can tell.
        h.http.publishLatest("Test/Addon", tag: "v2", flavors: ["mainline"])
        h.http.reset()

        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)
        #expect(h.http.apiRequests.count == 1)
        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)
        #expect(h.http.apiRequests.count == 1, "throttled: the last answer is reused")

        for await _ in h.manager.update([ref], in: h.installation) {}
        #expect(h.http.apiRequests.count == 2, "a single add-on's update always asks")

        h.http.publishLatest("Test/Addon", tag: "v3", flavors: ["mainline"])
        _ = try await h.manager.checkForUpdates(in: h.installation)
        #expect(h.http.apiRequests.count == 3, "a new latest tag makes the API check due")

        await h.manager.setClock { Date().addingTimeInterval(7 * 3600) }
        _ = try await h.manager.checkForUpdates(in: h.installation)
        #expect(h.http.apiRequests.count == 4, "and so do 6 hours")
    }

    @Test func openingDetailsTwiceInANewProcessCostsNothing() async throws {
        let h = try await ManagerHarness()
        let ref = AddonRef(source: .github, identifier: "A/Alpha")
        h.http.publishLatest("A/Alpha", tag: "v1")
        h.http.stub("https://raw.githubusercontent.com/A/Alpha/HEAD/README.md", text: "# Alpha")
        _ = try await h.manager.details(for: ref, in: h.installation)
        #expect(h.http.apiRequests.isEmpty)
        #expect(h.http.requests.count == 4, "HEAD, release.json (2 hops), README")
        h.http.reset()
        _ = try await (await h.reopen()).details(for: ref, in: h.installation)
        #expect(h.http.requests.isEmpty)
    }
}
