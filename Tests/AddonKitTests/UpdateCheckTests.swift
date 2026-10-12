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

    @Test func differingTagGoesThroughTheFullResolve() async throws {
        let h = try await ManagerHarness()
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(ref, into: h.installation)
        try h.publish("Test/Addon", [("v2", 2, 2), ("v1", 1, 1)])
        h.http.reset()

        guard case .available(let release) = try await h.manager.checkForUpdates(in: h.installation)[ref] else {
            Issue.record("expected an update")
            return
        }
        #expect(release.version == "v2")
        #expect(h.http.apiRequests.count == 1)
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
