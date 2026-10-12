import Foundation
import Synchronization
import Testing
@testable import AddonKit

/// Hits github.com and raw.githubusercontent.com for real. Run with `ADDONS_LIVE_TESTS=1`.
/// None of these spend API quota.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ADDONS_LIVE_TESTS"] == "1"))
struct LiveMetadataTests {
    let repos = [
        AddonRef(source: .github, identifier: "BigWigsMods/BigWigs"),
        AddonRef(source: .github, identifier: "DeadlyBossMods/DeadlyBossMods"),
    ]

    /// Fails the test if any request went to the API.
    final class CountingClient: HTTPClient {
        let inner = URLSessionHTTPClient()
        let api = Mutex(0)

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await data(for: request, followRedirects: true)
        }

        func data(for request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
            if request.url?.host() == "api.github.com" { api.withLock { $0 += 1 } }
            return try await inner.data(for: request, followRedirects: followRedirects)
        }
    }

    @Test func latestTagSupportAndResolveWithoutTheAPI() async throws {
        let http = CountingClient()
        let source = GitHub(http: http, database: try .inMemory()).latest
        for ref in repos {
            let latest = await source.latestRelease(for: ref, flavor: .forever, policy: .forceRevalidate, needBuild: true)
            let tag = try #require(latest.tag)
            #expect(latest.status == .supported(version: tag))
            #expect(await source.check(ref, flavor: .forever, policy: .preferStored) == SupportCheck(status: .supported(version: tag), tag: tag))
            let release = try #require(await source.resolvedRelease(ref, from: latest, flavor: .forever))
            #expect(release.version == tag)
            #expect(release.assetName.hasSuffix(".zip"))
            // The built asset URL exists (a HEAD that ends in a redirect to storage).
            var head = URLRequest(url: release.downloadURL)
            head.httpMethod = "HEAD"
            let (_, response) = try await http.data(for: head, followRedirects: false)
            #expect(response.statusCode == 302)
        }
        #expect(http.api.withLock { $0 } == 0)
    }

    @Test func readmesAndScreenshots() async throws {
        let source = GitHub(http: URLSessionHTTPClient()).readmes
        for ref in repos {
            guard case .found(let markdown, let path, let etag) = try await source.fetch(for: ref) else {
                Issue.record("no README for \(ref)")
                continue
            }
            #expect(!markdown.isEmpty)
            #expect(etag != nil)
            // A conditional request with the remembered path is a 304.
            #expect(try await source.fetch(for: ref, knownPath: path, etag: etag) == .notModified)
            let (owner, repo) = try GitHubSource.split(ref)
            let images = ReadmeImages.extract(from: markdown, owner: owner, repo: repo, readmePath: path)
            #expect(images.allSatisfy { !ReadmeImages.isBadgeOrIcon($0) })
        }
    }

    @Test func missingRepoAndRepoWithoutReleases() async throws {
        let source = GitHub(http: URLSessionHTTPClient()).latest
        #expect(await source.support(for: AddonRef(source: .github, identifier: "BigWigsMods/does-not-exist-zz9"), flavor: .forever) == .noReleases)
        let none = await source.latestRelease(for: AddonRef(source: .github, identifier: "torvalds/linux"), flavor: .forever, policy: .forceRevalidate)
        #expect(none == LatestRelease(tag: nil, status: .noReleases))
    }
}
