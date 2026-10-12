import Foundation
import Synchronization
import Testing
@testable import AddonKit

@Suite struct DownloaderSharingTests {
    let release = ResolvedRelease(
        ref: AddonRef(source: .github, identifier: "O/R"), name: "R", version: "v1", releaseID: 1,
        publishedAt: .now, downloadURL: URL(string: "https://example.com/r.zip")!, assetName: "R.zip"
    )

    @Test func oneCancelledWaiterDoesNotCancelTheSharedDownload() async throws {
        let transport = StubDownloadTransport()
        transport.stub(release.downloadURL, Data("zip".utf8))
        transport.delay = .milliseconds(200)
        let downloader = Downloader(cachesDirectory: try makeTempDirectory(), transport: transport)
        let release = self.release

        let first = Task { try await downloader.download(release) }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task { try await downloader.download(release) }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()

        let url = try await second.value
        #expect(try Data(contentsOf: url) == Data("zip".utf8))
        #expect(transport.requests.count == 1)
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func cancellingTheOnlyWaiterCancelsTheDownload() async throws {
        let transport = StubDownloadTransport()
        transport.stub(release.downloadURL, Data("zip".utf8))
        transport.delay = .seconds(10)
        let downloader = Downloader(cachesDirectory: try makeTempDirectory(), transport: transport)
        let release = self.release
        let task = Task { try await downloader.download(release) }
        try await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func progressIsThrottled() {
        let seen = Mutex<[Double]>([])
        let report = Downloader.throttle { value in seen.withLock { $0.append(value) } }
        for i in 0...1000 { report(Double(i) / 1000) }
        let values = seen.withLock { $0 }
        #expect(values.count <= 3, "a burst collapses to its first tick and the final one")
        #expect(values.last == 1)
    }
}
