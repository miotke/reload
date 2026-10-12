import Foundation
import Testing
@testable import AddonKit

/// `refresh(in:force:)`: phases, throttling, seeding and what later refreshes re-check.
@Suite struct RefreshTests {
    let installedRef = AddonRef(source: .github, identifier: "Test/Addon")

    /// A catalogue of four repos: three with release.json (one of them old), one without.
    func makeHarness(delay: Duration = .zero, updated: String = "2026-09-01T00:00:00Z") async throws -> ManagerHarness {
        let h = try await ManagerHarness(http: RedirectingHTTPClient(delay: delay))
        h.http.stub(CatalogueSource.defaultURL.absoluteString, text: catalogueCSV([
            ("A/Alpha", "Alpha", updated, true),
            ("B/Beta", "Beta", "2026-08-01T00:00:00Z", true),
            ("C/Gamma", "Gamma", "2026-07-01T00:00:00Z", false),
            ("D/Delta", "Delta", "2026-06-01T00:00:00Z", true),
        ]))
        h.http.publishLatest("A/Alpha", tag: "v1")
        h.http.publishLatest("B/Beta", tag: "v2", flavors: ["mainline"])
        h.http.publishLatest("D/Delta", tag: "v3", flavors: nil)
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(installedRef, into: h.installation)
        h.http.reset()
        return h
    }

    func run(_ h: ManagerHarness, force: Bool = false) async -> [RefreshProgress] {
        var events: [RefreshProgress] = []
        for await event in h.manager.refresh(in: h.installation, force: force) { events.append(event) }
        return events
    }

    @Test func firstRefreshRunsEveryPhaseInOrderWithoutTheAPI() async throws {
        let h = try await makeHarness()
        let events = await run(h)
        let order: [RefreshProgress.Phase] = [.catalogue, .updates, .support, .finished]
        let phases = events.map(\.phase)
        #expect(phases.map { order.firstIndex(of: $0)! } == phases.map { order.firstIndex(of: $0)! }.sorted())
        #expect(Set(phases) == Set(order))
        #expect(events.last?.phase == .finished)
        #expect(events.last?.updates?[installedRef] == .upToDate)
        #expect(events.map(\.fraction) == events.map(\.fraction).sorted())

        let support = events.filter { $0.phase == .support }
        #expect(support.last?.completed == support.last?.total)
        // Seed: the three release.json repos, plus the installed add-on.
        #expect(support.last?.total == 4)

        let cache = SupportCache(database: h.manager.database)
        #expect(await cache.status(for: AddonRef(source: .github, identifier: "A/Alpha")) == .supported(version: "v1"))
        #expect(await cache.status(for: AddonRef(source: .github, identifier: "B/Beta")) == .unsupported)
        #expect(await cache.status(for: AddonRef(source: .github, identifier: "D/Delta")) == .needsDownload)
        #expect(await cache.status(for: AddonRef(source: .github, identifier: "C/Gamma")) == nil)
        #expect(!h.http.urls.contains { $0.contains("C/Gamma") }, "no release.json: no request")
        #expect(h.http.apiRequests.isEmpty)
        #expect(await h.manager.lastRefresh(in: h.installation) != nil)
    }

    @Test func aRecentRefreshFinishesAtOnceWithStoredStates() async throws {
        let h = try await makeHarness()
        _ = await run(h)
        h.http.reset()
        let events = await run(h)
        #expect(events.map(\.phase) == [.finished])
        #expect(events[0].updates?[installedRef] == .upToDate)
        #expect(h.http.requests.isEmpty)
    }

    @Test func storedStatesAreCorrectedForWhatWasInstalledSince() async throws {
        let h = try await makeHarness()
        try h.publish("Test/Addon", [("v2", 2, 2), ("v1", 1, 1)])
        // Forced: the install just stored v1 as the latest tag, which a background refresh would reuse.
        let first = await run(h, force: true)
        guard case .available(let release)? = first.last?.updates?[installedRef] else {
            Issue.record("expected an update")
            return
        }
        for await _ in h.manager.update(releases: [release], in: h.installation) {}
        let again = await run(h)
        #expect(again.map(\.phase) == [.finished])
        #expect(again[0].updates?[installedRef] == .upToDate)
    }

    @Test func forcedRefreshChecksInstalledButNeverReseeds() async throws {
        let h = try await makeHarness()
        _ = await run(h)
        h.http.reset()
        let events = await run(h, force: true)
        #expect(events.last?.phase == .finished)
        #expect(h.http.urls.contains(CatalogueSource.defaultURL.absoluteString))
        #expect(h.http.urls.contains("https://github.com/Test/Addon/releases/latest"))
        #expect(!h.http.urls.contains { $0.contains("A/Alpha") || $0.contains("D/Delta") })
    }

    @Test func laterRefreshesRecheckOnlyReposTheCatalogueSaysChanged() async throws {
        let h = try await makeHarness()
        _ = await run(h)
        // Alpha changes after its verdict was stored.
        h.http.stub(CatalogueSource.defaultURL.absoluteString, text: catalogueCSV([
            ("A/Alpha", "Alpha", "2099-01-01T00:00:00Z", true),
            ("B/Beta", "Beta", "2026-08-01T00:00:00Z", true),
            ("C/Gamma", "Gamma", "2026-07-01T00:00:00Z", false),
            ("D/Delta", "Delta", "2026-06-01T00:00:00Z", true),
            ("E/Epsilon", "Epsilon", "2026-09-05T00:00:00Z", true),
        ]))
        h.http.publishLatest("A/Alpha", tag: "v1.1")
        h.http.publishLatest("E/Epsilon", tag: "v1")
        await h.manager.setClock { Date().addingTimeInterval(3 * 3600) }
        h.http.reset()
        let events = await run(h, force: true)
        #expect(events.filter { $0.phase == .support }.last?.total == 3, "Alpha, Epsilon and the installed add-on")
        #expect(h.http.urls.contains("https://github.com/A/Alpha/releases/latest"))
        #expect(h.http.urls.contains("https://github.com/E/Epsilon/releases/latest"), "new to the catalogue")
        #expect(!h.http.urls.contains { $0.contains("B/Beta") || $0.contains("D/Delta") })
        #expect(await SupportCache(database: h.manager.database).status(for: AddonRef(source: .github, identifier: "A/Alpha")) == .supported(version: "v1.1"))
    }

    @Test func throttleExpiresAfterTwoHours() async throws {
        let h = try await makeHarness()
        _ = await run(h)
        await h.manager.setClock { Date().addingTimeInterval(2 * 3600 + 60) }
        h.http.reset()
        let events = await run(h)
        #expect(events.count > 1)
        #expect(h.http.urls.contains("https://github.com/Test/Addon/releases/latest"))
    }

    @Test func checksRunAtMostFourAtATime() async throws {
        let h = try await makeHarness(delay: .milliseconds(20))
        _ = await run(h)
        #expect(h.http.peakInFlight <= AddonManager.refreshConcurrency)
    }

    @Test func cancellingStopsWithoutRecordingARefresh() async throws {
        let h = try await makeHarness(delay: .milliseconds(200))
        let manager = h.manager
        let installation = h.installation
        let consumer = Task {
            for await event in manager.refresh(in: installation, force: false) where event.phase == .updates { break }
        }
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(await h.manager.lastRefresh(in: h.installation) == nil)
    }

    @Test func storedUpdateStatesRoundTrip() {
        let release = ResolvedRelease(
            ref: installedRef, name: "Addon", version: "v2", releaseID: -5, publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            downloadURL: URL(string: "https://github.com/x/y/releases/download/v2/A.zip")!, assetName: "A.zip", changelog: "notes"
        )
        let states: [AddonRef: UpdateState] = [
            installedRef: .available(release),
            AddonRef(source: .github, identifier: "a/b"): .failed("boom"),
            AddonRef(source: .github, identifier: "c/d"): .pinned,
        ]
        #expect(StoredUpdateState.decode(StoredUpdateState.encode(states)) == states)
    }
}
