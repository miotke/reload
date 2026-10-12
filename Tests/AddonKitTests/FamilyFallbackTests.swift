import Foundation
import Testing
@testable import AddonKit

/// A Retail build on Forever only with an explicit opt-in, and how its updates behave (decision 0019).
@Suite struct FamilyFallbackTests {
    let ref = AddonRef(source: .github, identifier: "Test/Retail")

    /// The latest release is `tag` with a release.json naming `flavors`; its zip and the API's
    /// release list (one release, same release.json) are stubbed too.
    func publish(_ h: ManagerHarness, tag: String, id: Int64, flavors: [String]) throws {
        let repo = ref.identifier
        h.http.publishLatest(repo, tag: tag, flavors: flavors)
        let zip = try makeAddonZip(folders: ["Retail"], marker: tag, named: "\(tag).zip", in: makeTempDirectory())
        h.transport.stub(URL(string: "https://github.com/\(repo)/releases/download/\(tag)/Addon-\(tag).zip")!, try Data(contentsOf: zip))
        let metadata = flavors.map { #"{"flavor":"\#($0)","interface":120100}"# }.joined(separator: ",")
        let jsonURL = "https://downloads.test/\(repo)/\(tag)-release.json"
        h.http.stub(jsonURL, text: #"{"releases":[{"filename":"Addon-\#(tag).zip","nolib":false,"metadata":[\#(metadata)]}]}"#)
        let releases: [[String: Any]] = [[
            "id": id, "tag_name": tag, "name": tag, "draft": false, "prerelease": false,
            "published_at": "2026-10-0\(id)T12:00:00Z", "body": "",
            "assets": [
                ["id": id * 10, "name": "Addon-\(tag).zip", "state": "uploaded", "size": 100, "content_type": "application/zip",
                 "browser_download_url": "https://github.com/\(repo)/releases/download/\(tag)/Addon-\(tag).zip"],
                ["id": id * 10 + 1, "name": "release.json", "state": "uploaded", "size": 100, "content_type": "application/json",
                 "browser_download_url": jsonURL],
            ],
        ]]
        h.http.stub("https://api.github.com/repos/\(repo)/releases?per_page=10", headers: ["x-ratelimit-remaining": "55"],
                    body: try JSONSerialization.data(withJSONObject: releases))
    }

    @Test func retailBuildNeedsTheOptIn() async throws {
        let h = try await ManagerHarness()
        try publish(h, tag: "v1", id: 1, flavors: ["mainline"])
        await #expect(throws: AddonError.noCompatibleRelease(ref, .forever)) {
            try await h.manager.install(ref, into: h.installation)
        }
        let addon = try await h.manager.install(ref, into: h.installation, channel: .stable, force: false, allowFamilyFallback: true, progress: { _ in })
        #expect(addon.installedFlavorBuild == .mainline)
        #expect(addon.version == "v1")
        #expect(try await h.manager.installedAddons(in: h.installation).first?.installedFlavorBuild == .mainline)
    }

    @Test func retailBuildUpdatesStayRetailUntilAForeverBuildAppears() async throws {
        let h = try await ManagerHarness()
        try publish(h, tag: "v1", id: 1, flavors: ["mainline"])
        try await h.manager.install(ref, into: h.installation, channel: .stable, force: false, allowFamilyFallback: true, progress: { _ in })
        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)

        // A new Retail-only release: the update is the Retail build again.
        try publish(h, tag: "v2", id: 2, flavors: ["mainline"])
        guard case .available(let retail) = try await h.manager.checkForUpdates(in: h.installation)[ref] else {
            Issue.record("expected the v2 Retail build")
            return
        }
        #expect(retail.version == "v2")
        #expect(retail.flavorBuild == .mainline)
        var events: [OperationEvent] = []
        for await event in h.manager.update(releases: [retail], in: h.installation) { events.append(event) }
        let updated = try #require(try await h.manager.installedAddons(in: h.installation).first)
        #expect(updated.version == "v2" && updated.installedFlavorBuild == .mainline)

        // The same tag gains a Forever build: that's the update ("Forever build available").
        try publish(h, tag: "v2-forever", id: 3, flavors: ["mainline", "forever"])
        guard case .available(let forever) = try await h.manager.checkForUpdates(in: h.installation)[ref] else {
            Issue.record("expected the Forever build")
            return
        }
        #expect(forever.flavorBuild == nil)
        #expect(updated.isUpdate(forever))
        for await _ in h.manager.update(releases: [forever], in: h.installation) {}
        let switched = try #require(try await h.manager.installedAddons(in: h.installation).first)
        #expect(switched.installedFlavorBuild == nil)
        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)
    }

    @Test func ownBuildNeverSwitchesOnItsOwn() async throws {
        let h = try await ManagerHarness()
        try publish(h, tag: "v1", id: 1, flavors: ["forever", "mainline"])
        try await h.manager.install(ref, into: h.installation)
        // v2 drops Forever; the API's list has only v2, so there's no Forever build at all.
        try publish(h, tag: "v2", id: 2, flavors: ["mainline"])
        let state = try await h.manager.checkForUpdates(in: h.installation)[ref]
        #expect(state == .noCompatibleRelease)
        var events: [OperationEvent] = []
        for await event in h.manager.update([ref], in: h.installation) { events.append(event) }
        #expect(events.contains { if case .failed = $0 { true } else { false } })
        #expect(try await h.manager.installedAddons(in: h.installation).first?.installedFlavorBuild == nil)
    }

    @Test func storedUpdateStatesKeepTheBuild() {
        let release = ResolvedRelease(
            ref: ref, name: "R", version: "v2", releaseID: -5, publishedAt: Date(timeIntervalSince1970: 1),
            downloadURL: URL(string: "https://example.test/a.zip")!, assetName: "a.zip", flavorBuild: .mainline)
        let decoded = StoredUpdateState.decode(StoredUpdateState.encode([ref: .available(release)]))
        #expect(decoded[ref] == .available(release))
    }
}

/// `checkVisible`: quota-free checks for the rows on screen.
@Suite struct VisibleCheckTests {
    func refs(_ count: Int) -> [AddonRef] {
        (0..<count).map { AddonRef(source: .github, identifier: "o/r\($0)") }
    }

    func harness(delay: Duration = .zero, count: Int) async throws -> ManagerHarness {
        let h = try await ManagerHarness(http: RedirectingHTTPClient(delay: delay))
        await h.manager.setNetworkConstrained { false }
        for ref in refs(count) { h.http.publishLatest(ref.identifier, tag: "v1", flavors: ["mainline", "forever"]) }
        return h
    }

    @Test func atMostTwentyFourAtATimeAndNoAPI() async throws {
        let h = try await harness(delay: .milliseconds(20), count: 25)
        let all = refs(25)
        let checked = await h.manager.checkVisible(all + all.prefix(3), in: h.installation)
        #expect(checked == Array(all.prefix(20)))
        #expect(h.http.apiRequests.isEmpty)
        #expect(h.http.peakInFlight <= AddonManager.visibleCheckConcurrency)
        #expect(h.http.requests.filter { $0.httpMethod == "HEAD" }.count == 20)
        #expect(await h.manager.availableFlavors(for: [all[0]])[all[0]] == [.mainline, .forever])

        // Fresh answers are skipped: the next call only takes the five left.
        h.http.reset()
        #expect(await h.manager.checkVisible(all, in: h.installation) == Array(all.suffix(5)))
        #expect(h.http.requests.filter { $0.httpMethod == "HEAD" }.count == 5)
        h.http.reset()
        #expect(await h.manager.checkVisible(all, in: h.installation).isEmpty)
        #expect(h.http.requests.isEmpty)
    }

    @Test func dropsRefsAlreadyInFlight() async throws {
        let h = try await harness(delay: .milliseconds(200), count: 4)
        let manager = h.manager, installation = h.installation, targets = refs(4)
        let first = Task { await manager.checkVisible(targets, in: installation) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.checkVisible(targets, in: installation).isEmpty)
        #expect(await first.value == targets)
        #expect(h.http.requests.filter { $0.httpMethod == "HEAD" }.count == 4)
    }

    @Test func skipsOnLowDataModeAndWhileGitHubPauses() async throws {
        let h = try await harness(count: 2)
        await h.manager.setNetworkConstrained { true }
        #expect(await h.manager.checkVisible(refs(2), in: h.installation).isEmpty)
        #expect(h.http.requests.isEmpty)

        await h.manager.setNetworkConstrained { false }
        let blocked = AddonRef(source: .github, identifier: "o/blocked")
        h.http.stub("https://github.com/o/blocked/releases/latest", status: 403)
        #expect(await h.manager.checkVisible([blocked], in: h.installation) == [blocked])
        h.http.reset()
        #expect(await h.manager.checkVisible(refs(2), in: h.installation).isEmpty, "github.com asked us to back off")
        #expect(h.http.requests.isEmpty)
        #expect(h.http.apiRequests.isEmpty)
    }

    @Test func answersReachTheChangeStream() async throws {
        let h = try await harness(count: 1)
        let changes = await h.manager.database.changes()
        _ = await h.manager.checkVisible(refs(1), in: h.installation)
        var iterator = changes.makeAsyncIterator()
        let change = await iterator.next()
        #expect(change?.repos.contains("o/r0") == true)
        #expect(change?.tables.contains("repo_meta") == true)
    }
}
