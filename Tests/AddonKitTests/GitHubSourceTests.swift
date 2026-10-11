import Foundation
import Synchronization
import Testing
@testable import AddonKit

private let api = "https://api.github.com/repos/o/r/releases?per_page=10"
private let ref = AddonRef(source: .github, identifier: "o/r")

private func encode(_ releases: [GitHubRelease]) throws -> Data {
    try GitHubRelease.encoder.encode(releases)
}

private func encode(_ json: ReleaseJSON) throws -> Data {
    try JSONEncoder().encode(json)
}

private func zipData(_ files: [String: String]) throws -> Data {
    try Data(contentsOf: makeInspectorZip(files))
}

private final class TestClock: Sendable {
    private let mutex = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var date: Date {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}

@Suite struct GitHubSourceParseTests {
    @Test(arguments: [
        ("BigWigsMods/BigWigs", "BigWigsMods/BigWigs"),
        ("  BigWigsMods/BigWigs/ ", "BigWigsMods/BigWigs"),
        ("BigWigsMods/BigWigs.git", "BigWigsMods/BigWigs"),
        ("github:BigWigsMods/BigWigs", "BigWigsMods/BigWigs"),
        ("https://github.com/BigWigsMods/BigWigs", "BigWigsMods/BigWigs"),
        ("https://github.com/BigWigsMods/BigWigs/", "BigWigsMods/BigWigs"),
        ("https://github.com/BigWigsMods/BigWigs.git", "BigWigsMods/BigWigs"),
        ("http://www.github.com/BigWigsMods/BigWigs", "BigWigsMods/BigWigs"),
        ("github.com/DeadlyBossMods/DeadlyBossMods", "DeadlyBossMods/DeadlyBossMods"),
        ("https://github.com/BigWigsMods/BigWigs/releases", "BigWigsMods/BigWigs"),
        ("https://github.com/BigWigsMods/BigWigs/releases/tag/v426.4", "BigWigsMods/BigWigs"),
        ("https://github.com/BigWigsMods/BigWigs/tree/master", "BigWigsMods/BigWigs"),
        ("https://github.com/Tercioo/Plater-Nameplates?tab=readme", "Tercioo/Plater-Nameplates"),
        ("o/r.lua_x", "o/r.lua_x"),
    ])
    func accepts(input: String, identifier: String) {
        let ref = GitHubSource().parse(input)
        #expect(ref == AddonRef(source: .github, identifier: identifier))
    }

    @Test(arguments: [
        "", "BigWigs", "a/b/c", "/repo", "owner/", "-owner/repo", "own er/repo", "owner/..",
        "https://gitlab.com/o/r", "https://github.com/o", "https://github.com/o/r/issues/1",
        "ftp://github.com/o/r", "https://github.com.evil.com/o/r", "owner/re po", "owner/repo?x",
    ])
    func rejects(input: String) {
        #expect(GitHubSource().parse(input) == nil)
    }
}

@Suite struct GitHubSourceResolveTests {
    @Test func sendsHeadersWithoutTokenOrETag() async throws {
        let stub = StubHTTPClient()
        stub.stub(api, body: try encode([]))
        let source = GitHubSource(http: stub)
        await #expect(throws: AddonError.noCompatibleRelease(ref, .forever)) {
            _ = try await source.resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        }
        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == api)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func sendsTokenAndETagAnd304IsNotModified() async throws {
        let stub = StubHTTPClient()
        stub.stub(api, status: 304, headers: ["x-ratelimit-remaining": "4999", "x-ratelimit-reset": "1800000000"], body: Data())
        let source = GitHubSource(http: stub, token: "ghp_secret")
        let result = try await source.resolve(ref, flavor: .forever, channel: .stable, etag: #"W/"abc""#)
        guard case .notModified = result else {
            Issue.record("expected notModified, got \(result)")
            return
        }
        let request = try #require(stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_secret")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == #"W/"abc""#)
        let limit = await source.rateLimit()
        #expect(limit.remaining == 4999)
        #expect(limit.resetAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func notFound() async {
        let stub = StubHTTPClient()
        stub.stub(api, status: 404, body: Data(#"{"message":"Not Found"}"#.utf8))
        await #expect(throws: AddonError.notFound(ref)) {
            _ = try await GitHubSource(http: stub).resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        }
    }

    @Test func rateLimited403() async {
        let stub = StubHTTPClient()
        stub.stub(api, status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1791763105"], body: Data())
        let source = GitHubSource(http: stub)
        await #expect(throws: AddonError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_791_763_105))) {
            _ = try await source.resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        }
        let limit = await source.rateLimit()
        #expect(limit.remaining == 0)
    }

    @Test func rateLimited429RetryAfter() async {
        let stub = StubHTTPClient()
        stub.stub(api, status: 429, headers: ["Retry-After": "60"], body: Data())
        let source = GitHubSource(http: stub)
        let clock = TestClock()
        await source.setClock { clock.date }
        await #expect(throws: AddonError.rateLimited(resetAt: clock.date.addingTimeInterval(60))) {
            _ = try await source.resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        }
    }

    @Test func other403IsHTTPError() async {
        let stub = StubHTTPClient()
        stub.stub(api, status: 403, headers: ["x-ratelimit-remaining": "40"], body: Data())
        await #expect(throws: AddonError.http(status: 403, url: URL(string: api)!)) {
            _ = try await GitHubSource(http: stub).resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        }
    }

    @Test func recordedBigWigsResolvesForever() async throws {
        let bigwigs = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs")
        let stub = StubHTTPClient()
        stub.stub("https://api.github.com/repos/BigWigsMods/BigWigs/releases?per_page=10",
                  headers: ["ETag": #"W/"c095ce""#, "x-ratelimit-remaining": "59", "x-ratelimit-reset": "1791763105"],
                  body: try fixtureData("github/bigwigs-releases.json"))
        stub.stub("https://github.com/BigWigsMods/BigWigs/releases/download/v426.4/release.json",
                  body: try fixtureData("github/bigwigs-release-v426.4.json"))
        let source = GitHubSource(http: stub)

        let result = try await source.resolve(bigwigs, flavor: .forever, channel: .stable, etag: nil)
        guard case .release(let release, let etag) = result else {
            Issue.record("expected release, got \(result)")
            return
        }
        #expect(etag == #"W/"c095ce""#)
        #expect(release.ref == bigwigs)
        #expect(release.name == "BigWigs")
        #expect(release.version == "v426.4")
        #expect(release.releaseID == 409811185)
        #expect(release.assetName == "BigWigs-v426.4.zip")
        #expect(release.downloadURL.absoluteString == "https://github.com/BigWigsMods/BigWigs/releases/download/v426.4/BigWigs-v426.4.zip")
        #expect(release.publishedAt == ISO8601DateFormatter().date(from: "2026-10-11T17:21:55Z"))
        #expect(release.changelog?.contains("Bump version") == true)
        #expect(!release.isPrerelease)
        #expect(release.reasoning == ["release v426.4 (id 409811185)", "release.json → BigWigs-v426.4.zip (forever 16001)"])
        let downloadRequest = try #require(stub.requests.last)
        #expect(downloadRequest.value(forHTTPHeaderField: "Authorization") == nil)

        // Second resolve: the ETag is revalidated internally and release.json comes from memory.
        stub.stub("https://api.github.com/repos/BigWigsMods/BigWigs/releases?per_page=10", status: 304, body: Data())
        let again = try await source.resolve(bigwigs, flavor: .forever, channel: .stable, etag: nil)
        guard case .release(let r2, let etag2) = again else {
            Issue.record("expected release, got \(again)")
            return
        }
        #expect(r2.releaseID == 409811185)
        #expect(etag2 == #"W/"c095ce""#)
        #expect(stub.requests.count == 3)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "If-None-Match") == #"W/"c095ce""#)
    }

    @Test func newestWithoutForeverFallsBackToOlderRelease() async throws {
        let stub = StubHTTPClient()
        let releases = [
            ghRelease(2, tag: "v2", published: "2026-10-02T00:00:00Z", assets: [ghAsset(20, "A-v2.zip", tag: "v2"), ghAsset(21, "release.json", tag: "v2")]),
            ghRelease(1, tag: "v1", published: "2026-10-01T00:00:00Z", assets: [ghAsset(10, "A-v1.zip", tag: "v1"), ghAsset(11, "release.json", tag: "v1")]),
        ]
        stub.stub(api, body: try encode(releases))
        stub.stub("https://github.com/o/r/releases/download/v2/release.json",
                  body: try encode(ghReleaseJSON([("A-v2.zip", false, [("mainline", 120100)])])))
        stub.stub("https://github.com/o/r/releases/download/v1/release.json",
                  body: try encode(ghReleaseJSON([("A-v1-nolib.zip", true, [("forever", 16001)]), ("A-v1.zip", false, [("forever", 16001)])])))
        let result = try await GitHubSource(http: stub).resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        guard case .release(let release, _) = result else {
            Issue.record("expected release")
            return
        }
        #expect(release.releaseID == 1)
        #expect(release.assetName == "A-v1.zip")
        #expect(release.reasoning == [
            "release v2 (id 2)", "release.json has no forever entry; trying older release",
            "release v1 (id 1)", "release.json → A-v1.zip (forever 16001)",
        ])
    }

    @Test func noReleaseJSONInspectsZipsAndFallsBack() async throws {
        let stub = StubHTTPClient()
        let releases = [
            ghRelease(3, tag: "v3", prerelease: true, assets: [ghAsset(30, "A-v3.zip", tag: "v3")]),
            ghRelease(2, tag: "v2", assets: [ghAsset(20, "A-v2.zip", tag: "v2"), ghAsset(22, "A-v2-nolib.zip", tag: "v2")]),
            ghRelease(1, tag: "v1", assets: [ghAsset(10, "A-v1.zip", tag: "v1")]),
        ]
        stub.stub(api, body: try encode(releases))
        stub.stub("https://github.com/o/r/releases/download/v2/A-v2.zip", body: try zipData(["A/A.toc": "## Interface: 120100"]))
        stub.stub("https://github.com/o/r/releases/download/v1/A-v1.zip", body: try zipData(["A/A.toc": "## Interface: 120100", "A/A_Camelot.toc": "## Interface: 16001"]))
        let cache = try makeTempDirectory()
        let result = try await GitHubSource(http: stub, cacheDirectory: cache).resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        guard case .release(let release, _) = result else {
            Issue.record("expected release")
            return
        }
        #expect(release.releaseID == 1)
        #expect(release.assetName == "A-v1.zip")
        #expect(release.name == "r")
        #expect(release.reasoning == [
            "skipped prerelease v3 (id 3)",
            "release v2 (id 2): no forever zip found",
            "inspected A-v2.zip: no forever interface in A/A.toc [120100]",
            "release v1 (id 1)",
            "no release.json; candidates: A-v1.zip",
            "inspected A-v1.zip: A/A_Camelot.toc is forever-specific",
        ])
        let urls = stub.requests.compactMap { $0.url?.lastPathComponent }
        #expect(!urls.contains("A-v2-nolib.zip"))
        #expect(!urls.contains("A-v3.zip"))
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "downloads/github/10-A-v1.zip").path(percentEncoded: false)))
    }

    @Test func zipInspectionStopsAfterThreeReleases() async throws {
        let stub = StubHTTPClient()
        let retail = try zipData(["A/A.toc": "## Interface: 120100"])
        let releases = (1...5).reversed().map { i in
            ghRelease(Int64(i), tag: "v\(i)", assets: [ghAsset(Int64(i * 10), "A.zip", tag: "v\(i)")])
        }
        stub.stub(api, body: try encode(releases))
        for i in 1...5 {
            stub.stub("https://github.com/o/r/releases/download/v\(i)/A.zip",
                      body: i == 1 ? try zipData(["A/A_Camelot.toc": "## Interface: 16001"]) : retail)
        }
        await #expect(throws: AddonError.noCompatibleRelease(ref, .forever)) {
            _ = try await GitHubSource(http: stub).resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        }
        #expect(stub.requests.filter { $0.url?.lastPathComponent == "A.zip" }.count == 3)
    }

    @Test func releaseJSONCachedOnDisk() async throws {
        let stub = StubHTTPClient()
        let releases = [ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip"), ghAsset(11, "release.json")])]
        stub.stub(api, body: try encode(releases))
        stub.stub("https://github.com/o/r/releases/download/v1/release.json",
                  body: try encode(ghReleaseJSON([("A.zip", false, [("forever", 16001)])])))
        let cache = try makeTempDirectory()
        _ = try await GitHubSource(http: stub, cacheDirectory: cache).resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        #expect(stub.requests.count == 2)

        let fresh = GitHubSource(http: stub, cacheDirectory: cache)
        let result = try await fresh.resolve(ref, flavor: .forever, channel: .stable, etag: nil)
        guard case .release(let release, _) = result else {
            Issue.record("expected release")
            return
        }
        #expect(release.assetName == "A.zip")
        #expect(stub.requests.count == 3)
        #expect(stub.requests.last?.url?.host() == "api.github.com")
    }
}

@Suite struct GitHubSourceSupportTests {
    @Test func supported() async throws {
        let stub = StubHTTPClient()
        let releases = [ghRelease(1, tag: "v1.2", assets: [ghAsset(10, "A.zip", tag: "v1.2"), ghAsset(11, "release.json", tag: "v1.2")])]
        stub.stub(api, body: try encode(releases))
        stub.stub("https://github.com/o/r/releases/download/v1.2/release.json",
                  body: try encode(ghReleaseJSON([("A.zip", false, [("forever", 16001)])])))
        #expect(await GitHubSource(http: stub).support(for: ref, flavor: .forever) == .supported(version: "v1.2"))
    }

    @Test func needsDownloadWithoutDownloadingZips() async throws {
        let stub = StubHTTPClient()
        stub.stub(api, body: try encode([ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip")])]))
        #expect(await GitHubSource(http: stub).support(for: ref, flavor: .forever) == .needsDownload)
        #expect(stub.requests.count == 1)
    }

    @Test func noReleasesAndUnsupported() async throws {
        let stub = StubHTTPClient()
        stub.stub(api, body: try encode([ghRelease(1, tag: "v1", draft: true, assets: [])]))
        #expect(await GitHubSource(http: stub).support(for: ref, flavor: .forever) == .noReleases)

        stub.stub(api, body: try encode([ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip"), ghAsset(11, "release.json")])]))
        stub.stub("https://github.com/o/r/releases/download/v1/release.json",
                  body: try encode(ghReleaseJSON([("A.zip", false, [("mainline", 120100)])])))
        #expect(await GitHubSource(http: stub).support(for: ref, flavor: .forever) == .unsupported)
    }

    @Test func errorsAreUnknown() async {
        let stub = StubHTTPClient()
        stub.stub(api, status: 500, body: Data())
        #expect(await GitHubSource(http: stub).support(for: ref, flavor: .forever) == .unknown)
        #expect(await GitHubSource(http: stub).support(for: AddonRef(source: .tukui, identifier: "elvui"), flavor: .forever) == .unknown)
    }

    @Test func keepsQuotaReserve() async throws {
        let stub = StubHTTPClient()
        stub.stub(api, headers: ["x-ratelimit-remaining": "10", "x-ratelimit-reset": "1800003600"],
                  body: try encode([ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip")])]))
        let source = GitHubSource(http: stub)
        let clock = TestClock()
        await source.setClock { clock.date }
        #expect(await source.support(for: ref, flavor: .forever) == .needsDownload)

        let other = AddonRef(source: .github, identifier: "o/other")
        #expect(await source.support(for: other, flavor: .forever) == .unknown)
        #expect(stub.requests.count == 1)

        // Once the window resets, checks resume.
        clock.date = Date(timeIntervalSince1970: 1_800_003_601)
        _ = await source.support(for: other, flavor: .forever)
        #expect(stub.requests.count == 2)
    }

    @Test func cachesForSixHoursThenRevalidatesWithETag() async throws {
        let stub = StubHTTPClient()
        stub.stub(api, headers: ["ETag": #""v1""#, "x-ratelimit-remaining": "50"],
                  body: try encode([ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip")])]))
        let source = GitHubSource(http: stub)
        let clock = TestClock()
        await source.setClock { clock.date }
        #expect(await source.support(for: ref, flavor: .forever) == .needsDownload)
        clock.date += 5 * 3600
        #expect(await source.support(for: AddonRef(source: .github, identifier: "O/R"), flavor: .forever) == .needsDownload)
        #expect(stub.requests.count == 1)

        clock.date += 2 * 3600
        stub.stub(api, status: 304, headers: ["x-ratelimit-remaining": "50"], body: Data())
        #expect(await source.support(for: ref, flavor: .forever) == .needsDownload)
        #expect(stub.requests.count == 2)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "If-None-Match") == #""v1""#)
    }
}

@Suite struct GitHubSourceLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADDONS_LIVE_TESTS"] == "1"))
    func resolvesBigWigsForForever() async throws {
        let source = GitHubSource(token: ProcessInfo.processInfo.environment["GITHUB_TOKEN"])
        let bigwigs = try #require(source.parse("https://github.com/BigWigsMods/BigWigs"))
        let result = try await source.resolve(bigwigs, flavor: .forever, channel: .stable, etag: nil)
        guard case .release(let release, let etag) = result else {
            Issue.record("expected release")
            return
        }
        #expect(release.assetName.hasSuffix(".zip"))
        #expect(!release.assetName.contains("-nolib"))
        #expect(etag != nil)
        #expect(await source.support(for: bigwigs, flavor: .forever) == .supported(version: release.version))
    }
}
