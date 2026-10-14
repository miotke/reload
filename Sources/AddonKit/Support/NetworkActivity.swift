import Foundation
import Synchronization

/// One request the core made, for the app's Network Activity window
/// (docs/app/network-activity.md). A request is reported twice with the same `id`: when it
/// starts (`finishedAt` nil) and when it ends.
public struct NetworkEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// API calls, version checks, listings, READMEs: `HTTPClient` requests.
        case request
        /// Add-on zips, through the `DownloadTransport`.
        case download
    }

    public var id: Int
    public var kind: Kind
    public var method: String
    public var url: URL
    public var startedAt: Date
    /// Nil while the request is in flight.
    public var finishedAt: Date?
    public var status: Int?
    /// Body bytes received (the file size, for downloads).
    public var bytes: Int64?
    /// Where redirects ended, when that's not `url`.
    public var finalURL: URL?
    public var error: String?

    public init(
        id: Int, kind: Kind, method: String, url: URL, startedAt: Date, finishedAt: Date? = nil,
        status: Int? = nil, bytes: Int64? = nil, finalURL: URL? = nil, error: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.method = method
        self.url = url
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.bytes = bytes
        self.finalURL = finalURL
        self.error = error
    }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// Records every request the core's HTTP client and download transport make, keeps the last
/// `capacity`, and streams them to observers. Recording costs a lock and an append; nothing
/// is written to disk.
public final class NetworkActivityLog: Sendable {
    public static let capacity = 500

    private struct State {
        var nextID = 1
        /// Latest version of each recent event, oldest first.
        var recent: [NetworkEvent] = []
        var observers: [UUID: AsyncStream<NetworkEvent>.Continuation] = [:]
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// The recent events, then every start and finish as they happen. Updates to one request
    /// share its `id`.
    public func events() -> AsyncStream<NetworkEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkEvent.self, bufferingPolicy: .bufferingNewest(2 * Self.capacity))
        let key = UUID()
        state.withLock { state in
            for event in state.recent { continuation.yield(event) }
            state.observers[key] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: key) }
        }
        return stream
    }

    /// The recent events, oldest first.
    public var recent: [NetworkEvent] {
        state.withLock { $0.recent }
    }

    func begin(_ kind: NetworkEvent.Kind, method: String, url: URL) -> NetworkEvent {
        let date = now()
        return state.withLock { state in
            let event = NetworkEvent(id: state.nextID, kind: kind, method: method, url: url, startedAt: date)
            state.nextID += 1
            state.recent.append(event)
            if state.recent.count > Self.capacity { state.recent.removeFirst(state.recent.count - Self.capacity) }
            for observer in state.observers.values { observer.yield(event) }
            return event
        }
    }

    func finish(_ started: NetworkEvent, status: Int? = nil, bytes: Int64? = nil, finalURL: URL? = nil, error: (any Error)? = nil) {
        var event = started
        event.finishedAt = now()
        event.status = status
        event.bytes = bytes
        event.finalURL = finalURL == started.url ? nil : finalURL
        event.error = error.map(Self.describe)
        state.withLock { state in
            if let index = state.recent.lastIndex(where: { $0.id == event.id }) { state.recent[index] = event }
            for observer in state.observers.values { observer.yield(event) }
        }
    }

    private static func describe(_ error: any Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Cancelled" }
        return error.localizedDescription
    }
}

/// Wraps the core's `HTTPClient` so every request lands in the activity log.
struct RecordingHTTPClient: HTTPClient {
    let base: any HTTPClient
    let log: NetworkActivityLog

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await record(request) { try await base.data(for: request) }
    }

    func data(for request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        try await record(request) { try await base.data(for: request, followRedirects: followRedirects) }
    }

    private func record(
        _ request: URLRequest, _ body: () async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { return try await body() }
        let event = log.begin(.request, method: request.httpMethod ?? "GET", url: url)
        do {
            let (data, response) = try await body()
            log.finish(event, status: response.statusCode, bytes: Int64(data.count), finalURL: response.url)
            return (data, response)
        } catch {
            log.finish(event, error: error)
            throw error
        }
    }
}

/// Wraps the core's `DownloadTransport` so every add-on zip lands in the activity log.
struct RecordingDownloadTransport: DownloadTransport {
    let base: any DownloadTransport
    let log: NetworkActivityLog

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let event = log.begin(.download, method: "GET", url: url)
        do {
            try await base.download(from: url, to: destination, progress: progress)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
            log.finish(event, bytes: size)
        } catch {
            log.finish(event, error: error)
            throw error
        }
    }
}
