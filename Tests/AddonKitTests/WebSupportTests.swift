import Foundation
import Synchronization
import Testing
@testable import AddonKit

private let ref = AddonRef(source: .github, identifier: "o/r")

private func source(_ http: RedirectingHTTPClient, cache: URL? = nil) async -> GitHub {
    let source = GitHub(http: http, cacheDirectory: cache)
    await source.web.setRetryDelay { _, _ in .zero }
    return source
}

/// Support checks over github.com, which cost no API quota, and the cache policies that
/// decide when they touch the network.
@Suite struct WebSupportTests {
    @Test func supportedFromLatestReleaseJSON() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v2.0", flavors: ["mainline", "forever"])
        let source = await source(http)
        #expect(await source.latest.check(ref, flavor: .forever) == SupportCheck(status: .supported(version: "v2.0"), tag: "v2.0", availableFlavors: [.mainline, .forever]))
        #expect(http.apiRequests.isEmpty)
        // One HEAD, and the redirect isn't followed (that would download the release page).
        #expect(http.requests.first?.httpMethod == "HEAD")
        #expect(!http.urls.contains("https://github.com/o/r/releases/tag/v2.0"))
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        // The answer is stored, with its tag.
        #expect(await source.latest.store.record(for: ref, flavor: .forever)?.tag == "v2.0")
        #expect(await source.latest.store.latestTag(for: ref)?.tag == "v2.0")
    }

    @Test func releaseJSONWithoutTheFlavorIsUnsupported() async {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1", flavors: ["mainline", "classic"])
        #expect(await source(http).latest.support(for: ref, flavor: .forever) == .unsupported)
    }

    @Test func noReleaseJSONNeedsDownload() async {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1", flavors: nil)
        #expect(await source(http).latest.support(for: ref, flavor: .forever) == .needsDownload)
        #expect(http.apiRequests.isEmpty)
    }

    @Test func noReleasesOrMissingRepo() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: nil)
        #expect(await source(http).latest.check(ref, flavor: .forever) == SupportCheck(status: .noReleases, tag: nil))
        let missing = AddonRef(source: .github, identifier: "o/gone")
        #expect(await source(http).latest.support(for: missing, flavor: .forever) == .noReleases)
    }

    @Test func tagParsing() {
        #expect(GitHubWebClient.tag(fromReleaseURL: URL(string: "https://github.com/o/r/releases/tag/v1.2")) == "v1.2")
        #expect(GitHubWebClient.tag(fromReleaseURL: URL(string: "https://github.com/o/r/releases/tag/a%20b")) == "a b")
        #expect(GitHubWebClient.tag(fromReleaseURL: URL(string: "https://github.com/o/r/releases")) == nil)
        #expect(GitHubWebClient.releaseDownloadURL(owner: "o", repo: "r", tag: "a/b c", file: "release.json").absoluteString
            == "https://github.com/o/r/releases/download/a%2Fb%20c/release.json")
    }

    // MARK: Cache policies

    @Test func preferStoredNeverTouchesTheNetwork() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1")
        let source = await source(http)
        #expect(await source.latest.check(ref, flavor: .forever, policy: .preferStored) == SupportCheck(status: .unknown, tag: nil))
        #expect(http.requests.isEmpty)
        #expect(await source.latest.store.record(for: ref, flavor: .forever) == nil, "nothing written")

        _ = await source.latest.check(ref, flavor: .forever)
        http.reset()
        #expect(await source.latest.check(ref, flavor: .forever, policy: .preferStored).status == .supported(version: "v1"))
        #expect(http.requests.isEmpty)
    }

    @Test func revalidateIfStaleUsesTheTTLs() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1")
        let source = await source(http)
        let clock = MutableClock()
        await source.setClock(clock.now)
        _ = await source.latest.check(ref, flavor: .forever)
        http.reset()

        clock.date += SupportCache.defaultTTL - 60
        _ = await source.latest.check(ref, flavor: .forever)
        #expect(http.requests.isEmpty, "fresh: no request")

        clock.date += 120
        _ = await source.latest.check(ref, flavor: .forever)
        #expect(http.urls == ["https://github.com/o/r/releases/latest"], "stale, same tag: one HEAD, verdict reused")
        let stored = try #require(await source.latest.store.record(for: ref, flavor: .forever))
        #expect(stored.checkedAt == clock.date, "the revalidation is written")
    }

    @Test func negativeAndErrorAnswersHaveTheirOwnLifetimes() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: nil)
        http.stub("https://github.com/o/err/releases/latest", status: 500)
        let source = await source(http)
        let clock = MutableClock()
        await source.setClock(clock.now)
        let broken = AddonRef(source: .github, identifier: "o/err")
        // Quota is "comfortable", so the API fallback is tried; make it fail too.
        http.stub("https://api.github.com/repos/o/err/releases?per_page=10", status: 500)
        _ = await source.latest.check(ref, flavor: .forever)
        #expect(await source.latest.check(broken, flavor: .forever).status == .unknown)
        #expect(await source.latest.store.status(for: broken, flavor: .forever) == nil, "a failure is never shown")
        http.reset()

        clock.date += 10 * 60
        _ = await source.latest.check(ref, flavor: .forever)
        _ = await source.latest.check(broken, flavor: .forever)
        #expect(http.requests.isEmpty, "both within their lifetimes")

        clock.date += 10 * 60
        _ = await source.latest.check(ref, flavor: .forever)
        _ = await source.latest.check(broken, flavor: .forever)
        #expect(http.urls.contains("https://github.com/o/err/releases/latest"), "errors retry after 15 min")
        #expect(!http.urls.contains("https://github.com/o/r/releases/latest"), "negative answers last 24 h")
    }

    @Test func forceRevalidateAlwaysAsksButReusesTheVerdictForAnUnchangedTag() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1")
        let database = try MetadataDatabase.inMemory()
        _ = await GitHub(http: http, database: database).latest.check(ref, flavor: .forever)

        // A new process: release.json isn't fetched again for the same tag.
        http.reset()
        let source = GitHub(http: http, database: database)
        #expect(await source.latest.check(ref, flavor: .forever, policy: .forceRevalidate).status == .supported(version: "v1"))
        #expect(http.urls == ["https://github.com/o/r/releases/latest"])

        // A new tag means a new release.json.
        http.publishLatest("o/r", tag: "v2", flavors: ["mainline"])
        http.reset()
        #expect(await source.latest.check(ref, flavor: .forever, policy: .forceRevalidate).status == .unsupported)
        #expect(http.urls.contains { $0.hasSuffix("/v2/release.json") })
    }

    @Test func concurrentChecksShareOneRequest() async throws {
        let http = RedirectingHTTPClient(delay: .milliseconds(50))
        http.publishLatest("o/r", tag: "v1")
        let source = await source(http)
        async let a = source.latest.check(ref, flavor: .forever, policy: .forceRevalidate)
        async let b = source.latest.check(ref, flavor: .forever, policy: .forceRevalidate)
        let (first, second) = await (a, b)
        #expect(first == second)
        #expect(http.urls.filter { $0 == "https://github.com/o/r/releases/latest" }.count == 1)
    }

    @Test func quotaFreeResolveBuildsTheAssetURL() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v3")
        let release = try #require(await source(http).latest.quotaFreeResolve(ref, flavor: .forever, policy: .forceRevalidate))
        #expect(release.version == "v3")
        #expect(release.assetName == "Addon-v3.zip")
        #expect(release.downloadURL.absoluteString == "https://github.com/o/r/releases/download/v3/Addon-v3.zip")
        #expect(release.releaseID == LatestReleaseStore.syntheticReleaseID(ref: ref, tag: "v3"))
        #expect(http.apiRequests.isEmpty)

        // Without the flavor (or without release.json) only the API can decide.
        http.publishLatest("o/r", tag: "v4", flavors: ["mainline"])
        #expect(await source(http).latest.quotaFreeResolve(ref, flavor: .forever, policy: .forceRevalidate) == nil)
    }

    @Test func tagComparisonForQuotaFreeReleases() {
        let installed = sampleInstalledAddon("o/r", name: "R", folders: ["R"])   // v1, id 1
        var release = ResolvedRelease(
            ref: ref, name: "R", version: "v1", releaseID: LatestReleaseStore.syntheticReleaseID(ref: ref, tag: "v1"),
            publishedAt: .now, downloadURL: URL(string: "https://x")!, assetName: "R.zip"
        )
        #expect(!installed.isUpdate(release), "same tag, newer fake date: not an update")
        release.version = "v2"
        #expect(installed.isUpdate(release))
    }

    // MARK: Politeness

    @Test func retriesServerErrorsThenSucceeds() async throws {
        let http = FlakyHTTPClient(failures: 2, status: 503)
        http.inner.publishLatest("o/r", tag: "v1")
        let flaky = GitHub(http: http)
        await flaky.web.setRetryDelay { _, _ in .zero }
        #expect(await flaky.latest.check(ref, flavor: .forever).tag == "v1")
        #expect(http.attempts == 4) // 2 failures, the HEAD, then release.json
    }

    @Test func persistent429PausesWebRequests() async throws {
        let http = RedirectingHTTPClient()
        http.stub("https://github.com/o/r/releases/latest", status: 429, headers: ["Retry-After": "120"])
        let source = await source(http)
        #expect(await source.latest.check(ref, flavor: .forever).status == .unknown)
        #expect(http.requests.count == 1, "a long Retry-After isn't retried, and the API isn't asked instead")
        // While paused, other repos aren't requested from github.com at all.
        http.publishLatest("o/other", tag: "v1")
        #expect(await source.latest.check(AddonRef(source: .github, identifier: "o/other"), flavor: .forever).status == .unknown)
        #expect(http.requests.count == 1)
    }

    @Test func secondaryLimit403PausesForAMinute() async throws {
        let http = RedirectingHTTPClient()
        http.stub("https://github.com/o/r/releases/latest", status: 403)
        let source = await source(http)
        let clock = MutableClock()
        await source.setClock(clock.now)
        _ = await source.latest.check(ref, flavor: .forever)
        http.publishLatest("o/next", tag: "v1")
        clock.date += 30
        _ = await source.latest.check(AddonRef(source: .github, identifier: "o/next"), flavor: .forever)
        #expect(http.requests.count == 1)
        clock.date += 40
        _ = await source.latest.check(AddonRef(source: .github, identifier: "o/next"), flavor: .forever, policy: .forceRevalidate)
        #expect(http.urls.contains("https://github.com/o/next/releases/latest"))
    }

    @Test func webFailureFallsBackToTheAPIOnlyWithComfortableQuota() async throws {
        let http = RedirectingHTTPClient()
        http.stub("https://github.com/o/r/releases/latest", status: 500)
        http.stub("https://api.github.com/repos/o/r/releases?per_page=10", headers: ["x-ratelimit-remaining": "5"],
                  body: try GitHubRelease.encoder.encode([ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip")])]))
        let source = await source(http)
        #expect(await source.latest.support(for: ref, flavor: .forever) == .needsDownload)
        #expect(http.apiRequests.count == 1)

        // Quota is now low: another failure stays unknown without touching the API.
        let other = AddonRef(source: .github, identifier: "o/r2")
        http.stub("https://github.com/o/r2/releases/latest", status: 500)
        #expect(await source.latest.support(for: other, flavor: .forever) == .unknown)
        #expect(http.apiRequests.count == 1)
    }

    // MARK: Failures

    @Test func aBackgroundFailureKeepsTheVerdictAndNeverAsksTheAPI() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1")
        http.stub("https://api.github.com/repos/o/r/releases?per_page=10", headers: ["x-ratelimit-remaining": "55"],
                  body: try GitHubRelease.encoder.encode([ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip")])]))
        let source = await source(http)
        let clock = MutableClock()
        await source.setClock(clock.now)
        _ = await source.latest.check(ref, flavor: .forever)
        let checkedAt = clock.date

        clock.date += 2 * 3600
        http.stub("https://github.com/o/r/releases/latest", status: 500)
        http.reset()
        let answer = await source.latest.latestRelease(for: ref, flavor: .forever, policy: .revalidateIfStale, background: true)
        #expect(answer.status == .supported(version: "v1"), "the last good verdict is still shown")
        #expect(answer.tag == "v1")
        #expect(answer.failed)
        #expect(http.apiRequests.isEmpty)
        let record = try #require(await source.latest.store.record(for: ref, flavor: .forever))
        #expect(record.status == .supported(version: "v1") && record.checkedAt == checkedAt, "the verdict isn't overwritten")

        // Not retried for 15 minutes, then retried; a success clears the failure.
        clock.date += 10 * 60
        http.reset()
        _ = await source.latest.check(ref, flavor: .forever, background: true)
        #expect(http.requests.isEmpty)
        clock.date += 6 * 60
        http.publishLatest("o/r", tag: "v2")
        let retried = await source.latest.latestRelease(for: ref, flavor: .forever, policy: .revalidateIfStale, background: true)
        #expect(retried.status == .supported(version: "v2") && !retried.failed)
        #expect(await source.latest.store.storedSupport(for: ref, flavor: .forever)?.errorAt == nil)
    }

    @Test func aFailureWithNothingStoredIsUnknownAndNotAStatus() async throws {
        let http = RedirectingHTTPClient()
        http.stub("https://github.com/o/r/releases/latest", status: 500)
        let database = try MetadataDatabase.inMemory()
        let source = GitHub(http: http, database: database)
        await source.web.setRetryDelay { _, _ in .zero }
        #expect(await source.latest.check(ref, flavor: .forever, background: true).status == .unknown)
        #expect(await source.latest.store.status(for: ref, flavor: .forever) == nil)
        #expect(await source.latest.store.statuses(flavor: .forever).isEmpty)
        let row = try #require(try await database.query("SELECT status, error_at, retry_after FROM support").first)
        #expect(row.string(0) == nil && row.date(1) != nil && row.date(2) != nil)
    }

    @Test func theForegroundAPIFallbackIsAskedAtMostEverySixHours() async throws {
        let http = RedirectingHTTPClient()
        http.stub("https://github.com/o/r/releases/latest", status: 500)
        http.stub("https://api.github.com/repos/o/r/releases?per_page=10", headers: ["x-ratelimit-remaining": "55"],
                  body: try GitHubRelease.encoder.encode([ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip")])]))
        let source = await source(http)
        let clock = MutableClock()
        await source.setClock(clock.now)
        #expect(await source.latest.support(for: ref, flavor: .forever) == .needsDownload)
        #expect(http.apiRequests.count == 1)

        clock.date += 20 * 60
        #expect(await source.latest.check(ref, flavor: .forever, policy: .forceRevalidate).status == .needsDownload, "kept")
        #expect(http.apiRequests.count == 1)

        clock.date += 6 * 3600
        _ = await source.latest.check(ref, flavor: .forever, policy: .forceRevalidate)
        #expect(http.apiRequests.count == 2)
    }

    /// Callers can't bypass `check`: only the single owner, `LatestReleaseStore`, reaches the
    /// raw github.com lookups (defined in `GitHubWebClient`) and the stored rows.
    @Test func noCallerReachesTheRawLookups() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "LatestReleaseStore.swift" }
        let definedIn: [String: String] = [
            "fetchLatestTag(": "GitHubWebClient.swift", "fetchReleaseJSON(": "GitHubWebClient.swift",
            "webReleaseJSON(": "LatestReleaseStore.swift", "isFresh(": "SupportCache.swift", "storedSupport(": "SupportCache.swift",
        ]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (forbidden, owner) in definedIn {
                #expect(!text.contains(forbidden) || file.lastPathComponent == owner, "\(file.lastPathComponent) calls \(forbidden)")
            }
        }
    }
}


/// Fails the first `failures` requests with `status`, then delegates.
final class FlakyHTTPClient: HTTPClient, Sendable {
    let inner = RedirectingHTTPClient()
    private let failures: Int
    private let status: Int
    private let count = Mutex(0)

    init(failures: Int, status: Int) {
        self.failures = failures
        self.status = status
    }

    var attempts: Int { count.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n = count.withLock { value -> Int in
            value += 1
            return value
        }
        if n <= failures {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return try await inner.data(for: request)
    }
}

@Suite struct StoreChurnTests {
    @Test func noOpModifyLeavesTheFileAlone() async throws {
        let h = try await ManagerHarness()
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(AddonRef(source: .github, identifier: "Test/Addon"), into: h.installation)
        let before = try h.storeFileIdentity()
        try await h.manager.store.modify(h.installation) { _ in }
        try await h.manager.store.save(h.installation)
        #expect(try h.storeFileIdentity() == before)
    }

    @Test func updateCheckWithUnchangedETagDoesNotWrite() async throws {
        let h = try await ManagerHarness()
        let ref = AddonRef(source: .github, identifier: "Test/Addon")
        try h.publish("Test/Addon", [("v1", 1, 1)], etag: #""e1""#)
        try await h.manager.install(ref, into: h.installation)
        // Force the API path so ETags are involved: the free tag check can't settle it.
        try await h.manager.setChannel(.prerelease, for: ref, in: h.installation)

        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)
        #expect(try await h.manager.installedAddons(in: h.installation).first?.etag == #""e1""#)
        let before = try h.storeFileIdentity()

        // The same ETag again (here as a 304) must not touch the store.
        h.http.stub("https://api.github.com/repos/Test/Addon/releases?per_page=10", status: 304, headers: ["ETag": #""e1""#])
        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)
        #expect(try h.storeFileIdentity() == before)
    }
}
