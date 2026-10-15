import AddonKit
import Foundation
import Observation

/// One row of the Network Activity window, formatted once when its event arrives.
nonisolated struct ActivityRow: Identifiable, Hashable, Sendable {
    var id: Int
    var isDownload: Bool
    var url: URL
    var time: String
    var method: String
    var host: String
    var path: String
    var status: String
    var isFailure: Bool
    var isRunning: Bool
    var size: String
    var duration: String

    init(_ event: NetworkEvent) {
        id = event.id
        isDownload = event.kind == .download
        url = event.url
        time = event.startedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        method = event.method
        host = event.url.host() ?? ""
        let query = event.url.query().map { "?\($0)" } ?? ""
        path = event.url.path() + query
        isRunning = event.finishedAt == nil
        if let error = event.error {
            status = error
            isFailure = true
        } else if let code = event.status {
            // A redirect the client stopped at says where it pointed; one it followed, where it ended.
            status = event.finalURL.map { "\(code) → \($0.host() ?? "")" } ?? "\(code)"
            isFailure = code >= 400
        } else {
            status = isRunning ? (isDownload ? "Downloading…" : "Waiting…") : "Done"
            isFailure = false
        }
        size = event.bytes.map { $0.formatted(.byteCount(style: .file)) } ?? (isRunning ? "" : "—")
        duration = event.duration.map { Self.duration($0) } ?? ""
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }
}

/// The Network Activity window's rows (docs/app/network-activity.md). Follows the core's
/// `networkActivity()` from launch, so the window shows what happened before it opened, and
/// applies arrivals at most every `interval`: a refresh starts hundreds of requests.
@Observable @MainActor
final class NetworkActivityModel {
    /// Rows the table shows, newest first, already filtered.
    private(set) var visibleRows: [ActivityRow] = []
    var downloadsOnly = false {
        didSet { if downloadsOnly != oldValue { rebuild() } }
    }
    private(set) var requestCount = 0
    private(set) var downloadCount = 0
    private(set) var receivedBytes: Int64 = 0

    /// Every row kept, sorted by ID, which is oldest first.
    @ObservationIgnored private var rows: [ActivityRow] = []
    @ObservationIgnored private var bytesByID: [Int: Int64] = [:]
    @ObservationIgnored private var pending: [NetworkEvent] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    /// Events up to this ID were cleared; late finishes of cleared requests are ignored.
    @ObservationIgnored private var clearedThrough = 0

    static let interval: Duration = .milliseconds(100)
    /// Rows kept; the oldest go first.
    static let capacity = 1000

    func start(_ manager: any AddonManaging) {
        guard followTask == nil else { return }
        let events = manager.networkActivity()
        followTask = Task { [weak self] in
            for await event in events {
                self?.receive(event)
            }
        }
    }

    func receive(_ event: NetworkEvent) {
        pending.append(event)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.interval)
            self?.flush()
        }
    }

    /// Applies what arrived since the last flush.
    func flush() {
        flushTask = nil
        guard !pending.isEmpty else { return }
        for event in pending where event.id > clearedThrough {
            let row = ActivityRow(event)
            // A search per event, not a scan: a replay is 1,000 events into up to 1,000 rows.
            let index = position(of: event.id)
            if index < rows.count, rows[index].id == event.id {
                rows[index] = row
            } else {
                rows.insert(row, at: index)
            }
            if let bytes = event.bytes { bytesByID[event.id] = bytes }
        }
        pending = []
        if rows.count > Self.capacity {
            for row in rows.prefix(rows.count - Self.capacity) { bytesByID[row.id] = nil }
            rows.removeFirst(rows.count - Self.capacity)
        }
        rebuild()
    }

    func clear() {
        flush()
        clearedThrough = max(clearedThrough, rows.last?.id ?? 0)
        rows = []
        bytesByID = [:]
        rebuild()
    }

    func row(id: ActivityRow.ID) -> ActivityRow? {
        let index = position(of: id)
        return index < rows.count && rows[index].id == id ? rows[index] : nil
    }

    /// Where the row for `id` is, or would go, in `rows`.
    private func position(of id: ActivityRow.ID) -> Int {
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].id < id { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// "214 requests · 3 downloads · 6.1 MB"
    var summary: String {
        let requests = requestCount == 1 ? "1 request" : "\(requestCount) requests"
        let downloads = downloadCount == 1 ? "1 download" : "\(downloadCount) downloads"
        return "\(requests) · \(downloads) · \(receivedBytes.formatted(.byteCount(style: .file)))"
    }

    private func rebuild() {
        let shown = downloadsOnly ? rows.filter(\.isDownload) : rows
        let newestFirst = Array(shown.reversed())
        if newestFirst != visibleRows { visibleRows = newestFirst }
        let downloads = rows.count { $0.isDownload }
        if downloads != downloadCount { downloadCount = downloads }
        if rows.count - downloads != requestCount { requestCount = rows.count - downloads }
        let bytes = bytesByID.values.reduce(0, +)
        if bytes != receivedBytes { receivedBytes = bytes }
    }
}
