import AddonKit
import Foundation
import Testing

@MainActor @Suite struct NetworkActivityModelTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: Int, _ kind: NetworkEvent.Kind = .request, url: String = "https://api.tukui.org/v1/addons",
               finished: Bool = true, status: Int? = 200, bytes: Int64? = 1000, error: String? = nil) -> NetworkEvent {
        NetworkEvent(id: id, kind: kind, method: "GET", url: URL(string: url)!, startedAt: start,
                     finishedAt: finished ? start.addingTimeInterval(0.25) : nil,
                     status: finished ? status : nil, bytes: finished ? bytes : nil, error: error)
    }

    @Test func rowsAreNewestFirstAndUpdatedInPlace() {
        let model = NetworkActivityModel()
        model.receive(event(1))
        model.receive(event(2, .download, url: "https://cdn.test/a.zip", finished: false))
        model.flush()
        #expect(model.visibleRows.map(\.id) == [2, 1])
        #expect(model.visibleRows.first?.status == "Downloading…")

        model.receive(event(2, .download, url: "https://cdn.test/a.zip", status: nil, bytes: 2_000_000))
        model.flush()
        #expect(model.visibleRows.map(\.id) == [2, 1])
        #expect(model.visibleRows.first?.status == "Done")
        #expect(model.visibleRows.first?.duration == "250 ms")
        #expect(model.requestCount == 1 && model.downloadCount == 1)
        #expect(model.receivedBytes == 2_001_000)
    }

    @Test func downloadsOnly() {
        let model = NetworkActivityModel()
        model.receive(event(1))
        model.receive(event(2, .download, url: "https://cdn.test/a.zip"))
        model.flush()
        model.downloadsOnly = true
        #expect(model.visibleRows.map(\.id) == [2])
        model.downloadsOnly = false
        #expect(model.visibleRows.count == 2)
    }

    @Test func failuresAndRows() {
        let failed = ActivityRow(event(1, finished: true, status: nil, bytes: nil, error: "The Internet connection appears to be offline."))
        #expect(failed.isFailure && failed.status.hasPrefix("The Internet"))
        let missing = ActivityRow(event(2, status: 404))
        #expect(missing.isFailure && missing.status == "404")
        #expect(missing.host == "api.tukui.org" && missing.path == "/v1/addons")
        #expect(ActivityRow.duration(1.26) == "1.3 s")
    }

    @Test func clearIgnoresLateFinishes() {
        let model = NetworkActivityModel()
        model.receive(event(1, finished: false))
        model.flush()
        model.clear()
        #expect(model.visibleRows.isEmpty)
        model.receive(event(1))
        model.receive(event(2))
        model.flush()
        #expect(model.visibleRows.map(\.id) == [2])
    }

    @Test func keepsTheNewestRows() {
        let model = NetworkActivityModel()
        for id in 1...(NetworkActivityModel.capacity + 5) { model.receive(event(id)) }
        model.flush()
        #expect(model.visibleRows.count == NetworkActivityModel.capacity)
        #expect(model.visibleRows.last?.id == 6)
    }
}

/// Main-actor cost of applying network events (docs/performance/measurements.md#network-activity).
@MainActor @Suite(.serialized) struct NetworkActivityPerformanceTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: Int, finished: Bool) -> NetworkEvent {
        NetworkEvent(id: id, kind: id % 10 == 0 ? .download : .request, method: "GET",
                     url: URL(string: "https://github.com/owner\(id % 90)/Repo\(id)/releases/latest")!, startedAt: start,
                     finishedAt: finished ? start.addingTimeInterval(0.3) : nil,
                     status: finished ? 302 : nil, bytes: finished ? 1_200 : nil,
                     finalURL: finished ? URL(string: "https://github.com/owner\(id % 90)/Repo\(id)/releases/tag/v1") : nil)
    }

    /// A full window (1,000 rows) taking one 100 ms batch of a refresh: starts of new
    /// requests and finishes of ones already listed, then the replay of the core's 500
    /// recent events into a new window.
    @Test func flushingABatchStaysCheap() async {
        let model = NetworkActivityModel()
        for id in 1...NetworkActivityModel.capacity { model.receive(event(id, finished: false)) }
        model.flush()
        var next = NetworkActivityModel.capacity + 1
        let batch = await BrowsePerformanceTests.median(runs: 9) {
            // Requests started over the last second finish; as many new ones start.
            for id in (next - 60)..<(next - 30) { model.receive(event(id, finished: true)) }
            for id in next..<(next + 30) { model.receive(event(id, finished: false)) }
            next += 30
            model.flush()
        }
        #expect(model.visibleRows.count == NetworkActivityModel.capacity)
        #expect(model.visibleRows.first?.id == next - 1)

        let replay = await BrowsePerformanceTests.median(runs: 5) {
            let fresh = NetworkActivityModel()
            for id in 1...NetworkActivityLog.capacity { fresh.receive(event(id, finished: false)) }
            for id in 1...NetworkActivityLog.capacity { fresh.receive(event(id, finished: true)) }
            fresh.flush()
        }
        print("Network activity: 60-event batch into 1,000 rows \(BrowsePerformanceTests.ms(batch)), replay of 1,000 events \(BrowsePerformanceTests.ms(replay))")
        #expect(batch < budget(.milliseconds(4)), "batch took \(batch)")
        #expect(replay < budget(.milliseconds(25)), "replay took \(replay)")
    }
}
