import Foundation
import Testing
@testable import AddonKit

/// The activity log behind the app's Network Activity window (docs/app/network-activity.md).
@Suite struct NetworkActivityTests {
    @Test func requestsAreRecordedWithStatusAndSize() async throws {
        let h = try await ManagerHarness()
        h.http.stub("https://api.tukui.org/v1/addons", body: try fixtureData("sources/tukui-addons.json"))
        h.http.stub("https://example.test/missing", status: 404)
        _ = try await h.manager.http.data(for: URLRequest(url: URL(string: "https://api.tukui.org/v1/addons")!))
        _ = try await h.manager.http.data(for: URLRequest(url: URL(string: "https://example.test/missing")!))

        let events = h.manager.activity.recent
        #expect(events.map(\.url.absoluteString) == ["https://api.tukui.org/v1/addons", "https://example.test/missing"])
        #expect(events.map(\.status) == [200, 404])
        #expect(events[0].bytes == Int64(try fixtureData("sources/tukui-addons.json").count))
        #expect(events.allSatisfy { $0.kind == .request && $0.method == "GET" && $0.finishedAt != nil })
    }

    @Test func downloadsAreRecordedAsDownloads() async throws {
        let h = try await ManagerHarness()
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(AddonRef(source: .github, identifier: "Test/Addon"), into: h.installation)
        let downloads = h.manager.activity.recent.filter { $0.kind == .download }
        #expect(downloads.count == 1)
        #expect(downloads.first?.bytes ?? 0 > 0)
        #expect(downloads.first?.error == nil)
    }

    @Test func streamReplaysThenFollowsStartAndFinish() async throws {
        let log = NetworkActivityLog()
        let first = log.begin(.request, method: "HEAD", url: URL(string: "https://github.com/a/b/releases/latest")!)
        log.finish(first, status: 302)

        var iterator = log.events().makeAsyncIterator()
        #expect(await iterator.next()?.status == 302)
        let second = log.begin(.download, method: "GET", url: URL(string: "https://x.test/a.zip")!)
        log.finish(second, error: URLError(.notConnectedToInternet))
        let started = await iterator.next()
        let finished = await iterator.next()
        #expect(started?.id == second.id && started?.finishedAt == nil)
        #expect(finished?.id == second.id && finished?.error != nil)
    }

    @Test func keepsOnlyTheMostRecent() {
        let log = NetworkActivityLog()
        for i in 0..<(NetworkActivityLog.capacity + 10) {
            log.finish(log.begin(.request, method: "GET", url: URL(string: "https://x.test/\(i)")!), status: 200)
        }
        #expect(log.recent.count == NetworkActivityLog.capacity)
        #expect(log.recent.first?.url.lastPathComponent == "10")
    }
}
