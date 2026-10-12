import Foundation
import Synchronization
import Testing
@testable import AddonKit

private let ref = AddonRef(source: .github, identifier: "o/r")

private func source(_ http: RedirectingHTTPClient, cache: URL? = nil) async -> GitHubSource {
    let source = GitHubSource(http: http, cacheDirectory: cache)
    await source.setRetryDelay { _, _ in .zero }
    return source
}

/// Support checks and latest tags over github.com, which cost no API quota.
@Suite struct WebSupportTests {
    @Test func supportedFromLatestReleaseJSON() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v2.0", flavors: ["mainline", "forever"])
        #expect(await source(http).support(for: ref, flavor: .forever) == .supported(version: "v2.0"))
        #expect(http.apiRequests.isEmpty)
        #expect(http.requests.first?.httpMethod == "HEAD")
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func releaseJSONWithoutTheFlavorIsUnsupported() async {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1", flavors: ["mainline", "classic"])
        #expect(await source(http).support(for: ref, flavor: .forever) == .unsupported)
    }

    @Test func noReleaseJSONNeedsDownload() async {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1", flavors: nil)
        #expect(await source(http).support(for: ref, flavor: .forever) == .needsDownload)
        #expect(http.apiRequests.isEmpty)
    }

    @Test func noReleasesOrMissingRepo() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: nil)
        #expect(await source(http).support(for: ref, flavor: .forever) == .noReleases)
        #expect(try await source(http).latestTag(for: ref) == nil)

        // releases/latest itself 404s for a missing repo.
        let missing = AddonRef(source: .github, identifier: "o/gone")
        #expect(await source(http).support(for: missing, flavor: .forever) == .noReleases)
        await #expect(throws: AddonError.notFound(missing)) { try await source(http).latestTag(for: missing) }
    }

    @Test func latestTagIsReusedBriefly() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "release/1.0")
        let source = await source(http)
        #expect(try await source.latestTag(for: ref) == "release/1.0")
        #expect(try await source.latestTag(for: AddonRef(source: .github, identifier: "O/R")) == "release/1.0")
        // One HEAD, and the redirect isn't followed (that would download the release page).
        #expect(http.urls == ["https://github.com/o/r/releases/latest"])
        #expect(http.requests.first?.httpMethod == "HEAD")
    }

    @Test func tagParsing() {
        #expect(GitHubSource.tag(fromReleaseURL: URL(string: "https://github.com/o/r/releases/tag/v1.2")) == "v1.2")
        #expect(GitHubSource.tag(fromReleaseURL: URL(string: "https://github.com/o/r/releases/tag/a%20b")) == "a b")
        #expect(GitHubSource.tag(fromReleaseURL: URL(string: "https://github.com/o/r/releases")) == nil)
        #expect(GitHubSource.releaseDownloadURL(owner: "o", repo: "r", tag: "a/b c", file: "release.json").absoluteString
            == "https://github.com/o/r/releases/download/a%2Fb%20c/release.json")
    }

    @Test func unchangedTagReusesTheStoredVerdict() async throws {
        let database = try MetadataDatabase.inMemory()
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1")
        let first = GitHubSource(http: http, database: database)
        let check = await first.check(ref, flavor: .forever)
        #expect(check == SupportCheck(status: .supported(version: "v1"), tag: "v1"))
        await SupportCache(database: database).set(check.status, for: ref, tag: check.tag)

        // A new process: the tag is unchanged, so release.json isn't fetched again.
        http.reset()
        #expect(await GitHubSource(http: http, database: database).support(for: ref, flavor: .forever) == .supported(version: "v1"))
        #expect(http.urls == ["https://github.com/o/r/releases/latest"])

        // A new tag means a new release.json.
        http.publishLatest("o/r", tag: "v2", flavors: ["mainline"])
        http.reset()
        #expect(await GitHubSource(http: http, database: database).support(for: ref, flavor: .forever) == .unsupported)
        #expect(http.urls.contains { $0.hasSuffix("/v2/release.json") })
    }

    @Test func webResolveBuildsTheAssetURLWithoutTheAPI() async throws {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v3")
        let release = try #require(try await source(http).webResolve(ref, flavor: .forever))
        #expect(release.version == "v3")
        #expect(release.assetName == "Addon-v3.zip")
        #expect(release.downloadURL.absoluteString == "https://github.com/o/r/releases/download/v3/Addon-v3.zip")
        #expect(release.releaseID < 0)
        #expect(release.releaseID == GitHubSource.syntheticReleaseID(ref: ref, tag: "v3"))
        #expect(http.apiRequests.isEmpty)

        // Without the flavor (or without release.json) only the API can decide.
        http.publishLatest("o/r", tag: "v4", flavors: ["mainline"])
        #expect(try await source(http).webResolve(ref, flavor: .forever) == nil)
    }

    @Test func tagComparisonForQuotaFreeReleases() {
        let installed = sampleInstalledAddon("o/r", name: "R", folders: ["R"])   // v1, id 1
        var release = ResolvedRelease(
            ref: ref, name: "R", version: "v1", releaseID: GitHubSource.syntheticReleaseID(ref: ref, tag: "v1"),
            publishedAt: .now, downloadURL: URL(string: "https://x")!, assetName: "R.zip"
        )
        #expect(!installed.isUpdate(release), "same tag, newer fake date: not an update")
        release.version = "v2"
        #expect(installed.isUpdate(release))
    }

    @Test func retriesServerErrorsThenSucceeds() async throws {
        let http = FlakyHTTPClient(failures: 2, status: 503)
        http.inner.publishLatest("o/r", tag: "v1")
        let flaky = GitHubSource(http: http)
        await flaky.setRetryDelay { _, _ in .zero }
        #expect(try await flaky.latestTag(for: ref) == "v1")
        #expect(http.attempts == 3)
    }

    @Test func persistent429PausesWebRequests() async throws {
        let http = RedirectingHTTPClient()
        http.stub("https://github.com/o/r/releases/latest", status: 429, headers: ["Retry-After": "120"])
        let source = await source(http)
        await #expect(throws: AddonError.self) { try await source.latestTag(for: ref) }
        #expect(http.requests.count == 1) // a long Retry-After isn't retried
        // While paused, other repos aren't requested from github.com at all.
        http.publishLatest("o/other", tag: "v1")
        await #expect(throws: AddonError.self) {
            try await source.latestTag(for: AddonRef(source: .github, identifier: "o/other"))
        }
        #expect(http.requests.count == 1)
    }

    @Test func webFailureFallsBackToTheAPIOnlyWithComfortableQuota() async throws {
        let http = RedirectingHTTPClient()
        http.stub("https://github.com/o/r/releases/latest", status: 500)
        http.stub("https://api.github.com/repos/o/r/releases?per_page=10", headers: ["x-ratelimit-remaining": "5"],
                  body: try GitHubRelease.encoder.encode([ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip")])]))
        let source = await source(http)
        #expect(await source.support(for: ref, flavor: .forever) == .needsDownload)
        #expect(http.apiRequests.count == 1)

        // Quota is now low: another failure stays unknown without touching the API.
        let other = AddonRef(source: .github, identifier: "o/r2")
        http.stub("https://github.com/o/r2/releases/latest", status: 500)
        #expect(await source.support(for: other, flavor: .forever) == .unknown)
        #expect(http.apiRequests.count == 1)
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
