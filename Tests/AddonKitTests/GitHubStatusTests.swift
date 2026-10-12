import Foundation
import Testing
@testable import AddonKit

/// `gitHubStatus()`: quota and pause state from memory and the database, never the network.
struct GitHubStatusTests {
    @Test func freshManagerKnowsNothingAndMakesNoRequests() async throws {
        let h = try await ManagerHarness()
        let status = await h.manager.gitHubStatus()
        #expect(status == GitHubStatus(apiLimit: 60, hasToken: false))
        #expect(h.http.requests.isEmpty)
    }

    @Test func readsStoredRowsWrittenByAnotherProcess() async throws {
        let h = try await ManagerHarness()
        let clock = MutableClock()
        let reset = clock.date.addingTimeInterval(600)
        await h.manager.database.setRateLimit("core", RateLimitState(remaining: 12, resetAt: reset), at: clock.date)
        await h.manager.database.setRateLimit("search", RateLimitState(remaining: 0, resetAt: reset), at: clock.date)
        let manager = await h.reopen()
        await manager.setClock(clock.now)

        let status = await manager.gitHubStatus()
        #expect(status.api == RateLimitState(remaining: 12, resetAt: reset))
        #expect(status.search == RateLimitState(remaining: 0, resetAt: reset))
        let legacy = await manager.rateLimit()
        #expect(legacy.remaining == 12 && legacy.resetAt == reset)
        #expect(h.http.requests.isEmpty)
    }

    @Test func windowPastItsResetIsReportedFull() async throws {
        let h = try await ManagerHarness()
        let clock = MutableClock()
        await h.manager.setClock(clock.now)
        let reset = clock.date.addingTimeInterval(60)
        await h.manager.database.setRateLimit("search", RateLimitState(remaining: 0, resetAt: reset), at: clock.date)
        #expect(await h.manager.gitHubStatus().search == RateLimitState(remaining: 0, resetAt: reset))

        clock.date = reset.addingTimeInterval(1)
        #expect(await h.manager.gitHubStatus().search == RateLimitState(remaining: 10, resetAt: nil))
    }

    @Test func tokenRaisesTheLimits() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = AddonManager(
            directories: AppDirectories(root: root),
            http: StubHTTPClient(),
            locator: InstallationLocator(baseFolders: [], findApps: { [] }),
            keychain: KeychainStore(service: "AddonKitTests-\(UUID().uuidString)"),
            environment: ["ADDONS_GITHUB_TOKEN": "t0ken"]
        )
        let clock = MutableClock()
        await manager.setClock(clock.now)
        await manager.database.setRateLimit("search", RateLimitState(remaining: 1, resetAt: clock.date.addingTimeInterval(-1)), at: clock.date)

        let status = await manager.gitHubStatus()
        #expect(status.hasToken)
        #expect(status.apiLimit == 5000)
        #expect(status.search == RateLimitState(remaining: 30, resetAt: nil))
    }

    @Test func apiLimitFollowsTheLimitHeader() async throws {
        let stub = StubHTTPClient()
        // A repo without releases: the headers still count.
        stub.stub("https://api.github.com/repos/o/r/releases/latest", status: 404,
                  headers: ["x-ratelimit-limit": "15000", "x-ratelimit-remaining": "14999"], body: Data())
        let api = GitHubAPIClient(http: stub, token: "t0ken")
        #expect(await api.quotaLimit() == 5000)
        _ = try await api.releaseNotes(for: AddonRef(source: .github, identifier: "o/r"), tag: nil)
        #expect(await api.quotaLimit() == 15000)

        await api.setToken(nil)
        #expect(await api.quotaLimit() == 60)
    }

    @Test func reportsTheWebPauseUntilItEnds() async throws {
        let h = try await ManagerHarness()
        let clock = MutableClock()
        await h.manager.setClock(clock.now)
        let url = "https://github.com/o/r/releases/latest"
        h.http.stub(url, status: 403)
        _ = try? await h.manager.github.web.request(URL(string: url)!, method: "HEAD", followRedirects: false)

        #expect(await h.manager.gitHubStatus().webPausedUntil == clock.date.addingTimeInterval(60))
        clock.date = clock.date.addingTimeInterval(61)
        #expect(await h.manager.gitHubStatus().webPausedUntil == nil)
    }
}
