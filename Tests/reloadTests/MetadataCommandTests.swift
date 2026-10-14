import AddonKit
import Foundation
import Synchronization
import Testing
@testable import reload

// MARK: - Offline harness

/// Answers from a route table and records every request. Unknown URLs get a 404.
final class StubHTTP: HTTPClient, Sendable {
    private struct State {
        var routes: [String: (status: Int, headers: [String: String], body: Data)] = [:]
        var requests: [URLRequest] = []
    }
    private let state = Mutex(State())

    var requests: [URLRequest] { state.withLock { $0.requests } }
    /// Requests that count against the GitHub API quota.
    var apiRequests: [URLRequest] { requests.filter { $0.url?.host() == "api.github.com" } }
    var heads: [URLRequest] { requests.filter { $0.httpMethod == "HEAD" } }

    func stub(_ url: String, status: Int = 200, headers: [String: String] = [:], body: String = "") {
        state.withLock { $0.routes[url] = (status, headers, Data(body.utf8)) }
    }

    /// `repo`'s latest release is `tag`, with a release.json that has a Forever build.
    func publishLatest(_ repo: String, tag: String) {
        stub("https://github.com/\(repo)/releases/latest", status: 302, headers: ["Location": "https://github.com/\(repo)/releases/tag/\(tag)"])
        let folder = repo.split(separator: "/").last!
        stub("https://github.com/\(repo)/releases/download/\(tag)/release.json", body: """
            {"releases":[{"name":"\(folder)","version":"\(tag)","filename":"\(folder)-\(tag).zip","nolib":false,"metadata":[{"flavor":"forever","interface":16001}]}]}
            """)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await data(for: request, followRedirects: true)
    }

    func data(for request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let route = state.withLock { state in
            state.requests.append(request)
            return state.routes[url.absoluteString]
        }
        let (status, headers, body) = route ?? (404, [:], Data())
        return (request.httpMethod == "HEAD" ? Data() : body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

struct NoDownloads: DownloadTransport {
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        throw URLError(.notConnectedToInternet)
    }
}

/// A `CLIContext` over a temp `RELOAD_DATA_DIR`, a fake `_classic_beta_` tree and stubbed
/// HTTP. Never touches the real Keychain item or Application Support.
struct CLIHarness {
    let root: URL
    let http = StubHTTP()
    let context: CLIContext
    let installation: Installation

    init() async throws {
        root = try temporaryDirectory()
        let wow = root.appending(path: "World of Warcraft/_classic_beta_", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wow.appending(path: "Interface/AddOns"), withIntermediateDirectories: true)
        let environment = [
            "RELOAD_DATA_DIR": root.appending(path: "data").path(percentEncoded: false),
            "RELOAD_GITHUB_TOKEN": "test-token",
        ]
        var context = CLIContext(
            options: try GlobalOptions.parse(["--quiet"]), environment: environment,
            console: Console(stdinIsTTY: false, stdoutIsTTY: false, stderrIsTTY: false))
        context.keychain = KeychainStore(service: "reloadTests-\(UUID().uuidString)")
        context.manager = AddonManager(
            directories: context.directories, http: http, downloadTransport: NoDownloads(),
            locator: CLIEnvironment.locator(environment), keychain: context.keychain, environment: environment)
        self.context = context
        installation = try await context.manager.addInstallation(at: wow)
    }

    func install(_ addon: InstalledAddon) async throws {
        try await context.manager.store.upsert(addon, in: installation)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - update

@Suite struct UpdateCommandTests {
    @Test func planInstallsOnlyAvailable() {
        let a = makeAddon("o/A"), b = makeAddon("o/B"), c = makeAddon("o/C", pinned: true), d = makeAddon("o/D"), e = makeAddon("o/E")
        let release = ResolvedRelease(ref: a.id, name: "A", version: "v2", releaseID: -5, publishedAt: .now,
                                      downloadURL: URL(string: "https://github.com/o/A/releases/download/v2/A.zip")!, assetName: "A.zip")
        let plan = UpdateCommand.plan([a, b, c, d, e], states: [
            a.id: .available(release), b.id: .upToDate, c.id: .pinned, d.id: .failed("boom"),
        ], flavor: .forever)
        #expect(plan.install == [release])
        #expect(plan.skipped == [.init(ref: b.id, reason: "Up to date"), .init(ref: c.id, reason: "Pinned")])
        #expect(plan.failed.map(\.ref) == [d.id, e.id])
        #expect(plan.failed.map(\.message) == ["boom", "Not checked"])
    }

    /// A release.json add-on whose latest tag is unchanged: one quota-free HEAD, nothing else.
    @Test func updateWithNothingNewUsesNoAPIQuota() async throws {
        let h = try await CLIHarness()
        defer { h.cleanUp() }
        try await h.install(makeAddon("Test/Addon", version: "v1"))
        h.http.publishLatest("Test/Addon", tag: "v1")

        let installed = try await h.context.manager.installedAddons(in: h.installation)
        try await UpdateCommand.perform([], installed: installed, context: h.context, installation: h.installation)

        #expect(h.http.apiRequests.isEmpty)
        #expect(h.http.heads.count == 1, "checked once, not again by an empty update(releases:)")
        #expect(try await h.context.manager.installedAddons(in: h.installation).first?.version == "v1")
    }
}

// MARK: - cache

@Suite struct CacheCommandTests {
    @Test func reportsMetadataDatabaseAndLegacyFiles() async throws {
        let h = try await CLIHarness()
        defer { h.cleanUp() }
        let directories = h.context.directories
        let fm = FileManager.default
        try fm.createDirectory(at: directories.downloadsDirectory, withIntermediateDirectories: true)
        try Data(count: 10).write(to: directories.downloadsDirectory.appending(path: "a.zip"))
        try Data(count: 5).write(to: directories.caches.appending(path: SupportCache.fileName))
        _ = try await h.context.manager.database.execute("INSERT INTO rate_limit(resource, remaining, updated_at) VALUES ('x', 1, 0)")

        let cache = CacheCommand.cacheUsage(of: directories).map(\.name)
        #expect(cache == ["Downloaded archives", "Old support cache (unused)"])
        let metadata = CacheCommand.metadataUsage(of: directories)
        #expect(metadata.first?.name == "Metadata database")
        #expect(metadata.first?.path.hasSuffix("Application Support/metadata.sqlite") == true)
        #expect(metadata.contains { $0.name == "Metadata write-ahead log" })
    }

    @Test func clearKeepsMetadataUnlessAsked() async throws {
        let h = try await CLIHarness()
        defer { h.cleanUp() }
        let directories = h.context.directories
        let database = h.context.manager.database
        try FileManager.default.createDirectory(at: directories.downloadsDirectory, withIntermediateDirectories: true)
        try Data(count: 10).write(to: directories.downloadsDirectory.appending(path: "a.zip"))
        // The app's screenshot cache lives in Caches too, so it goes with the downloads.
        try FileManager.default.createDirectory(at: directories.screenshotsDirectory, withIntermediateDirectories: true)
        try Data(count: 10).write(to: directories.screenshotsDirectory.appending(path: "Cache.db"))
        #expect(CacheCommand.cacheUsage(of: directories).map(\.name).contains("Screenshot images"))
        await h.context.manager.database.setRateLimit("core", RateLimitState(remaining: 0, resetAt: .now.addingTimeInterval(600)), at: .now)
        _ = try await database.execute("""
            INSERT INTO support(full_name, flavor, status, version, tag, checked_at) VALUES ('o/r', 'forever', 'supported', 'v1', 'v1', 0)
            """)

        var context = h.context
        context.yes = true
        try await CacheCommand.Clear.parse([]).run(context)
        #expect(CacheCommand.cacheUsage(of: directories).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directories.screenshotsDirectory.path(percentEncoded: false)))
        #expect(try await MetadataInfo.counts(database).support == 1)

        try await CacheCommand.Clear.parse(["--metadata"]).run(context)
        #expect(try await MetadataInfo.counts(database) == .init(catalogue: 0, support: 0))
        #expect(FileManager.default.fileExists(atPath: MetadataInfo.databaseURL(directories).path(percentEncoded: false)))
        // An exhausted quota is remembered, so nothing spends requests GitHub would refuse.
        #expect(await database.rateLimit("core")?.remaining == 0)
    }

    @Test func clearNeedsConfirmationWithoutATerminal() async throws {
        let h = try await CLIHarness()
        defer { h.cleanUp() }
        await #expect(throws: CLIError.confirmationRequired("cache clear")) {
            try await CacheCommand.Clear.parse(["--metadata"]).run(h.context)
        }
    }
}

// MARK: - doctor

@Suite struct DoctorMetadataTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func rateLimitStates() {
        let ok = DoctorCommand.rateLimitCheck(name: "GitHub API", .init(remaining: 42, resetAt: now.addingTimeInterval(1800), updatedAt: now.addingTimeInterval(-300)), now: now)
        #expect(ok.level == .ok)
        #expect(ok.message.hasPrefix("42 calls left, resets"))
        #expect(ok.message.hasSuffix("(seen 5 minutes ago)"))

        let low = DoctorCommand.rateLimitCheck(name: "GitHub API", .init(remaining: 3, resetAt: now.addingTimeInterval(60)), now: now)
        #expect(low.level == .warning)
        let out = DoctorCommand.rateLimitCheck(name: "GitHub API", .init(remaining: 0, resetAt: now.addingTimeInterval(60)), now: now)
        #expect(out.level == .warning)
        #expect(out.message.hasPrefix("Rate limited"))
        let reset = DoctorCommand.rateLimitCheck(name: "GitHub API", .init(remaining: 0, resetAt: now.addingTimeInterval(-1)), now: now)
        #expect(reset.level == .ok)
        #expect(reset.message == "Quota has reset since it was last seen")
    }

    @Test func lastRefresh() {
        let installation = makeInstallation("abcd")
        #expect(DoctorCommand.lastRefresh(nil, installation: installation).level == .warning)
        let done = DoctorCommand.lastRefresh(now.addingTimeInterval(-7200), installation: installation, now: now)
        #expect(done == .init(name: "Refresh abcd", level: .ok, message: "Last refreshed 2 hours ago"))
    }

    @Test func metadataDatabase() async throws {
        let memory = try MetadataDatabase.inMemory()
        #expect(await DoctorCommand.metadata(memory, url: nil).first?.level == .error)

        let h = try await CLIHarness()
        defer { h.cleanUp() }
        let database = h.context.manager.database
        let checks = await DoctorCommand.metadata(database, url: database.url)
        #expect(checks.first?.level == .ok)
        #expect(checks.first?.message.contains("metadata.sqlite schema v6") == true)
        #expect(checks.first?.message.contains("0 catalogue rows, 0 support verdicts") == true)
        #expect(checks.contains { $0.name == "Catalogue" && $0.level == .warning })
    }

    @Test func storedRateLimitIsRead() async throws {
        let database = try MetadataDatabase.inMemory()
        #expect(await MetadataInfo.rateLimit("core", in: database) == nil)
        await database.setRateLimit("search", RateLimitState(remaining: 7, resetAt: now), at: now)
        #expect(await MetadataInfo.rateLimit("search", in: database) == .init(remaining: 7, resetAt: now, updatedAt: now))
    }
}

// MARK: - refresh

@Suite struct RefreshCommandTests {
    @Test func summaryLines() {
        var summary = RefreshCommand.Summary()
        summary.record(RefreshProgress(phase: .finished, completed: 1, total: 1, message: "Up to date", updates: [:]))
        #expect(summary.skipped)
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(RefreshCommand.summaryLines(summary, flavor: .forever, lastRefresh: now.addingTimeInterval(-600), now: now)
            == ["Already refreshed 10 minutes ago; use --force to refresh now."])

        let release = ResolvedRelease(ref: ref("o/A"), name: "A", version: "v2", releaseID: -1, publishedAt: now,
                                      downloadURL: URL(string: "https://example.com/a.zip")!, assetName: "a.zip")
        summary = RefreshCommand.Summary()
        summary.record(RefreshProgress(phase: .catalogue, completed: 1, total: 1))
        summary.record(RefreshProgress(phase: .updates, completed: 2, total: 2))
        summary.record(RefreshProgress(phase: .support, completed: 40, total: 40))
        summary.record(RefreshProgress(phase: .finished, updates: [ref("o/A"): .available(release), ref("o/B"): .failed("x")]))
        #expect(!summary.skipped)
        #expect(RefreshCommand.summaryLines(summary, flavor: .forever, lastRefresh: now) == [
            "Catalogue: checked",
            "Updates: checked 2 installed add-ons, 1 available, 1 failed",
            "Forever support: checked 40 of 40 add-ons",
        ])
    }

    @Test func progressText() {
        let text = RefreshCommand.progressText(RefreshProgress(phase: .support, completed: 5, total: 20, message: "Checked BigWigs"), style: .plain)
        #expect(text == "[3/3] Checked BigWigs  5/20 ━━━━────────────")
        #expect(RefreshCommand.progressText(RefreshProgress(phase: .catalogue, completed: 0, total: 1, message: "Downloading"), style: .plain) == "[1/3] Downloading")
    }

    /// The installed add-on is checked on github.com only; a second run soon after is skipped.
    @Test func refreshIsQuotaFreeAndThrottled() async throws {
        let h = try await CLIHarness()
        defer { h.cleanUp() }
        try await h.install(makeAddon("Test/Addon", version: "v1"))
        h.http.publishLatest("Test/Addon", tag: "v1")
        h.http.stub(CatalogueSource.defaultURL.absoluteString, body: """
            id,name,full_name,url,description,last_updated,flavors,curse_id,wago_id,wowi_id,has_release_json,last_seen
            1,Addon,Test/Addon,https://github.com/Test/Addon,Addon add-on,2026-10-01T00:00:00Z,mainline,,,,True,2026-10-01T00:00:00Z
            """)

        try await RefreshCommand.parse([]).run(h.context)
        #expect(h.http.apiRequests.isEmpty)
        #expect(await h.context.manager.lastRefresh(in: h.installation) != nil)
        #expect(try await MetadataInfo.counts(h.context.manager.database).catalogue == 1)

        var summary = RefreshCommand.Summary()
        for await progress in h.context.manager.refresh(in: h.installation, force: false) { summary.record(progress) }
        #expect(summary.skipped)
        #expect(summary.updates?[ref("Test/Addon")] == .upToDate)
    }
}

// MARK: - search and info

@Suite struct SearchAndInfoTests {
    @Test func collectNotesGitHubOnce() async {
        let result = SearchResult(id: ref("o/r"), name: "r", owner: "o", support: .needsDownload, origin: [.github])
        let updates = AsyncStream<SearchUpdate> { continuation in
            continuation.yield(SearchUpdate(results: []))
            continuation.yield(SearchUpdate(results: [], isSearchingGitHub: true))
            continuation.yield(SearchUpdate(results: [result], isComplete: true))
            continuation.finish()
        }
        let calls = Mutex(0)
        let (results, searched) = await SearchCommand.collect(updates) { calls.withLock { $0 += 1 } }
        #expect(searched)
        #expect(results == [result])
        #expect(calls.withLock { $0 } == 1)

        let local = AsyncStream<SearchUpdate> { continuation in
            continuation.yield(SearchUpdate(results: [result], isComplete: true))
            continuation.finish()
        }
        #expect(await SearchCommand.collect(local).searchedGitHub == false)
    }

    @Test func uncheckedGamesShowAsADash() {
        #expect(Format.games(nil, flavor: .forever, style: .plain) == "—")
    }

    @Test func stableStateFromStoredDetails() {
        let addon = makeAddon("o/r", version: "v1")
        #expect(InfoCommand.stableState(addon, latestVersion: "v1", support: .supported(version: "v1")) == UpdateStateJSON(.upToDate))
        #expect(InfoCommand.stableState(addon, latestVersion: "v2", support: .supported(version: "v2")) == UpdateStateJSON(state: "available", version: "v2"))
        #expect(InfoCommand.stableState(addon, latestVersion: "v2", support: .unsupported) == UpdateStateJSON(.noCompatibleRelease))
        #expect(InfoCommand.stableState(addon, latestVersion: nil, support: .unknown) == UpdateStateJSON(state: "unknown"))
        #expect(InfoCommand.stableState(makeAddon("o/r", pinned: true), latestVersion: "v2", support: .unknown) == UpdateStateJSON(.pinned))
    }

    @Test func readmeDescription() {
        #expect(InfoCommand.readmeDescription(path: "docs/README.md", hasReadme: true) == "docs/README.md")
        #expect(InfoCommand.readmeDescription(path: "", hasReadme: false) == "none")
        #expect(InfoCommand.readmeDescription(path: nil, hasReadme: false) == "not fetched yet")
    }

    /// `info` reads the catalogue row and stored details; a fresh details row costs nothing.
    @Test func infoUsesStoredDetailsWithoutTheNetwork() async throws {
        let h = try await CLIHarness()
        defer { h.cleanUp() }
        let database = h.context.manager.database
        let now = Date()
        _ = try await database.execute("""
            INSERT INTO details(full_name, flavor, readme, screenshots_json, latest_version, fetched_at)
            VALUES ('Test/Addon', 'forever', '# Hi', '["https://example.com/a.png","https://example.com/b.png"]', 'v3', ?)
            """, now)
        _ = try await database.execute("INSERT INTO repo_meta(full_name, readme_path) VALUES ('Test/Addon', 'README.md')")

        try await InfoCommand.parse(["Test/Addon"]).run(h.context)
        #expect(h.http.requests.isEmpty)
        let details = try await h.context.manager.details(for: ref("Test/Addon"), in: h.installation)
        #expect(details.latestVersion == "v3")
        #expect(details.screenshots.count == 2)
        #expect(await MetadataInfo.readmePath(for: ref("Test/Addon"), in: database) == "README.md")
    }
}
