import Foundation
@testable import AddonKit

/// URL of a file under `Tests/AddonKitTests/Fixtures/`, e.g. `fixtureURL("github/releases.json")`.
func fixtureURL(_ path: String) -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures").appending(path: path)
}

func fixtureData(_ path: String) throws -> Data {
    try Data(contentsOf: fixtureURL(path))
}

/// A fresh empty directory under the system temp dir, removed by the caller (or the OS).
func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "AddonKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Serves canned responses keyed by absolute URL string; records every request.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { _requests } }

    func stub(_ url: String, _ response: Response) {
        lock.withLock { responses[url] = response }
    }

    func stub(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data) {
        stub(url, Response(status: status, headers: headers, body: body))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = request.url!.absoluteString
        let response: Response? = lock.withLock {
            _requests.append(request)
            return responses[key]
        }
        guard let response else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!
        return (response.body, http)
    }
}
