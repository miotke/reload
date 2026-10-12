import Foundation
import Synchronization
@testable import AddonKit

/// Like `StubHTTPClient`, but follows redirects the way `URLSession` does: the caller sees
/// only the final response, whose `url` is where the redirects ended up.
final class RedirectingHTTPClient: HTTPClient, Sendable {
    enum Route {
        case respond(status: Int, headers: [String: String], body: Data)
        case redirect(String)
    }

    private struct State {
        var routes: [String: Route] = [:]
        var requests: [URLRequest] = []
        var inFlight = 0
        var peakInFlight = 0
    }

    private let state = Mutex(State())
    private let delay: Duration

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    /// Every request, including each hop of a redirect chain.
    var requests: [URLRequest] { state.withLock { $0.requests } }
    var urls: [String] { requests.map { $0.url!.absoluteString } }
    /// Requests that count against the GitHub API quota.
    var apiRequests: [URLRequest] { requests.filter { $0.url?.host() == "api.github.com" } }
    var peakInFlight: Int { state.withLock { $0.peakInFlight } }

    func stub(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        state.withLock { $0.routes[url] = .respond(status: status, headers: headers, body: body) }
    }

    func stub(_ url: String, text: String) {
        stub(url, body: Data(text.utf8))
    }

    func redirect(_ url: String, to target: String) {
        state.withLock { $0.routes[url] = .redirect(target) }
    }

    func reset() {
        state.withLock { $0.requests = [] }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await data(for: request, followRedirects: true)
    }

    func data(for request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        state.withLock {
            $0.inFlight += 1
            $0.peakInFlight = max($0.peakInFlight, $0.inFlight)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }

        var url = request.url!
        for _ in 0..<10 {
            var hop = request
            hop.url = url
            let route: Route? = state.withLock {
                $0.requests.append(hop)
                return $0.routes[url.absoluteString]
            }
            switch route {
            case .redirect(let target):
                guard followRedirects else {
                    return (Data(), HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target])!)
                }
                url = URL(string: target)!
            case .respond(let status, let headers, let body):
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
                return (request.httpMethod == "HEAD" ? Data() : body, response)
            case nil:
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }
        throw URLError(.httpTooManyRedirects)
    }
}

extension RedirectingHTTPClient {
    /// Stubs github.com so `owner/repo`'s latest release is `tag`, optionally with a
    /// release.json listing `flavors` (nil means the release has no release.json).
    func publishLatest(_ repo: String, tag: String?, flavors: [String]? = ["forever"]) {
        let latest = "https://github.com/\(repo)/releases/latest"
        guard let tag else {
            // A repo without releases redirects to its (empty) releases page.
            redirect(latest, to: "https://github.com/\(repo)/releases")
            stub("https://github.com/\(repo)/releases")
            return
        }
        redirect(latest, to: "https://github.com/\(repo)/releases/tag/\(tag)")
        stub("https://github.com/\(repo)/releases/tag/\(tag)")
        let download = "https://github.com/\(repo)/releases/download/\(tag)/release.json"
        if let flavors {
            let metadata = flavors.map { #"{"flavor":"\#($0)","interface":16001}"# }.joined(separator: ",")
            let json = #"{"releases":[{"name":"Addon","version":"\#(tag)","filename":"Addon-\#(tag).zip","nolib":false,"metadata":[\#(metadata)]}]}"#
            let asset = "https://release-assets.test/\(repo)/\(tag)/release.json"
            redirect(download, to: asset)
            stub(asset, text: json)
        } else {
            stub(download, status: 404)
        }
    }
}

/// A clock tests can move.
final class MutableClock: Sendable {
    private let mutex = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var date: Date {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
    var now: @Sendable () -> Date { { self.date } }
}

/// An `AddonManager` over a temp folder, a fake WoW install and redirect-aware stubs.
struct ManagerHarness {
    let root: URL
    let installRoot: URL
    let http: RedirectingHTTPClient
    let transport = StubDownloadTransport()
    let manager: AddonManager
    let installation: Installation

    var directories: AppDirectories { AppDirectories(root: root.appending(path: "AppData")) }

    init(http: RedirectingHTTPClient = RedirectingHTTPClient()) async throws {
        self.http = http
        root = try makeTempDirectory()
        installRoot = root.appending(path: "World of Warcraft/_classic_beta_", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: installRoot.appending(path: "Interface/AddOns"), withIntermediateDirectories: true)
        manager = AddonManager(
            directories: AppDirectories(root: root.appending(path: "AppData")),
            http: http,
            downloadTransport: transport,
            locator: InstallationLocator(baseFolders: [], findApps: { [] }),
            installer: Installer(trash: { try FileManager.default.removeItem(at: $0) }),
            keychain: KeychainStore(service: "AddonKitTests-\(UUID().uuidString)"),
            environment: [:]
        )
        installation = try await manager.addInstallation(at: installRoot)
        await manager.setRetryDelay { _, _ in .zero }
    }

    /// Stubs the API releases list and the free github.com routes for `repo`, with
    /// `versions` newest first, each carrying a Forever release.json and a zip.
    func publish(_ repo: String, _ versions: [(tag: String, id: Int64, day: Int)], etag: String? = nil) throws {
        let folder = String(repo.split(separator: "/").last!)
        var releases: [[String: Any]] = []
        for v in versions {
            let zipURL = "https://downloads.test/\(repo)/\(v.tag).zip"
            let jsonURL = "https://downloads.test/\(repo)/\(v.tag)-release.json"
            let zip = try makeAddonZip(folders: [folder], marker: v.tag, named: "\(v.tag).zip", in: makeTempDirectory())
            let zipData = try Data(contentsOf: zip)
            transport.stub(URL(string: zipURL)!, zipData)
            // The quota-free route builds the asset URL from release.json's filename.
            transport.stub(URL(string: "https://github.com/\(repo)/releases/download/\(v.tag)/Addon-\(v.tag).zip")!, zipData)
            let releaseJSON = #"{"releases":[{"filename":"\#(folder)-\#(v.tag).zip","nolib":false,"metadata":[{"flavor":"forever","interface":16001}]}]}"#
            http.stub(jsonURL, text: releaseJSON)
            releases.append([
                "id": v.id, "tag_name": v.tag, "name": v.tag, "draft": false, "prerelease": false,
                "published_at": "2026-10-\(String(format: "%02d", v.day))T12:00:00Z", "body": "Notes for \(v.tag)",
                "assets": [
                    ["id": v.id * 10, "name": "\(folder)-\(v.tag).zip", "state": "uploaded", "size": 100,
                     "content_type": "application/zip", "browser_download_url": zipURL],
                    ["id": v.id * 10 + 1, "name": "release.json", "state": "uploaded", "size": 100,
                     "content_type": "application/json", "browser_download_url": jsonURL],
                ],
            ])
        }
        var headers = ["x-ratelimit-remaining": "55"]
        if let etag { headers["ETag"] = etag }
        http.stub("https://api.github.com/repos/\(repo)/releases?per_page=10", headers: headers,
                  body: try JSONSerialization.data(withJSONObject: releases))
        http.publishLatest(repo, tag: versions.first?.tag)
    }

    /// The installation's store file, for checking whether something wrote to it.
    var storeFile: URL {
        directories.installationsDirectory.appending(path: "\(installation.id).json")
    }

    /// Changes whenever the store file is replaced (atomic writes swap the inode).
    func storeFileIdentity() throws -> [String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: storeFile.path(percentEncoded: false))
        return ["\(attributes[.systemFileNumber] ?? "")", "\(attributes[.modificationDate] ?? "")"]
    }
}

/// Minimal catalogue CSV with the columns `CatalogueCSV` reads.
func catalogueCSV(_ rows: [(repo: String, name: String, updated: String, releaseJSON: Bool)]) -> String {
    var lines = ["id,name,full_name,url,description,last_updated,flavors,curse_id,wago_id,wowi_id,has_release_json,last_seen"]
    for (i, row) in rows.enumerated() {
        let url = "https://github.com/\(row.repo)"
        lines.append("\(i + 1),\(row.name),\(row.repo),\(url),\(row.name) add-on,\(row.updated),mainline,,,,\(row.releaseJSON ? "True" : "False"),\(row.updated)")
    }
    return lines.joined(separator: "\n") + "\n"
}
