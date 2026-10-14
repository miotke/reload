import Foundation
import Synchronization
@testable import AddonKit

/// URL of a file under `Tests/AddonKitTests/Fixtures/`, e.g. `fixtureURL("github/releases.json")`.
func fixtureURL(_ path: String) -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures").appending(path: path)
}

func fixtureData(_ path: String) throws -> Data {
    try Data(contentsOf: fixtureURL(path))
}

/// A timing budget scaled by `RELOAD_PERF_SLACK` (1 when unset). CI sets 3: shared runners
/// are slower, and the budgets are there to catch O(n²) work, not a slow machine.
func budget(_ duration: Duration) -> Duration {
    duration * (Double(ProcessInfo.processInfo.environment["RELOAD_PERF_SLACK"] ?? "") ?? 1)
}

/// A fresh empty directory under the system temp dir, removed by the caller (or the OS).
func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "AddonKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Serves canned responses keyed by absolute URL string; records every request.
final class StubHTTPClient: HTTPClient, Sendable {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private struct State {
        var responses: [String: Response] = [:]
        var requests: [URLRequest] = []
    }

    private let state = Mutex(State())

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func stub(_ url: String, _ response: Response) {
        state.withLock { $0.responses[url] = response }
    }

    func stub(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data) {
        stub(url, Response(status: status, headers: headers, body: body))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = request.url!.absoluteString
        let response: Response? = state.withLock {
            $0.requests.append(request)
            return $0.responses[key]
        }
        guard let response else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!
        return (response.body, http)
    }
}
