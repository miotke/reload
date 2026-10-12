import Foundation
import Testing
@testable import AddonKit

/// Update checks use the free latest-tag route first and only call the API when it can't decide.
@Suite struct CheapUpdateCheckTests {
    let ref = AddonRef(source: .github, identifier: "Test/Addon")

    @Test func matchingLatestTagSkipsTheAPI() async throws {
        let h = try await ManagerHarness()
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(ref, into: h.installation)
        h.http.reset()
        let before = try h.storeFileIdentity()

        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)
        #expect(h.http.apiRequests.isEmpty)
        #expect(try h.storeFileIdentity() == before)
    }

    @Test func newTagWithReleaseJSONIsFoundWithoutTheAPI() async throws {
        let h = try await ManagerHarness()
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(ref, into: h.installation)
        #expect(h.http.apiRequests.isEmpty, "a stable install with release.json is quota-free")
        try h.publish("Test/Addon", [("v2", 2, 2), ("v1", 1, 1)])
        h.http.reset()

        guard case .available(let release) = try await h.manager.checkForUpdates(in: h.installation)[ref] else {
            Issue.record("expected an update")
            return
        }
        #expect(release.version == "v2")
        #expect(release.downloadURL.absoluteString == "https://github.com/Test/Addon/releases/download/v2/Addon-v2.zip")
        #expect(h.http.apiRequests.isEmpty)

        // Installing exactly that release, then checking again: up to date, still no API.
        var events: [OperationEvent] = []
        for await event in h.manager.update(releases: [release], in: h.installation) { events.append(event) }
        #expect(events.contains { if case .done(let addon) = $0 { addon.version == "v2" } else { false } })
        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)
        #expect(h.http.apiRequests.isEmpty)
    }

    @Test func newTagWithoutTheFlavorFallsBackToTheAPI() async throws {
        let h = try await ManagerHarness()
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(ref, into: h.installation)
        // v2 drops Forever from its release.json; the API path finds v1 is still newest for it.
        h.http.publishLatest("Test/Addon", tag: "v2", flavors: ["mainline"])
        h.http.reset()
        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)
        #expect(h.http.apiRequests.count == 1)
    }

    @Test func updateWithNoRefsChecksFirstAndSkipsUpToDate() async throws {
        let h = try await ManagerHarness()
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(ref, into: h.installation)
        h.http.reset()
        var skipped: [String] = []
        for await event in h.manager.update([], in: h.installation) {
            if case .skipped(_, let reason) = event { skipped.append(reason) }
        }
        #expect(skipped == ["Up to date"])
        #expect(h.http.apiRequests.isEmpty)
        #expect(h.transport.requests.count == 1, "no second download")
    }

    @Test func prereleaseChannelAlwaysUsesTheAPI() async throws {
        let h = try await ManagerHarness()
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(ref, into: h.installation, channel: .prerelease)
        h.http.reset()
        #expect(try await h.manager.checkForUpdates(in: h.installation)[ref] == .upToDate)
        #expect(h.http.apiRequests.count == 1)
        #expect(!h.http.urls.contains { $0.hasSuffix("/releases/latest") })
    }
}
