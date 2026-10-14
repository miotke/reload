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
