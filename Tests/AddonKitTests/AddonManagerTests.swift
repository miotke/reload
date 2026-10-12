import Foundation
import Testing
@testable import AddonKit

/// End-to-end: install → check → update → rollback → pinned skip → uninstall, fully offline.
@Suite struct AddonManagerTests {
    let root: URL
    let installRoot: URL
    let http = StubHTTPClient()
    let transport = StubDownloadTransport()
    let manager: AddonManager

    static let ref = AddonRef(source: .github, identifier: "Test/Addon")
    static let releasesURL = "https://api.github.com/repos/Test/Addon/releases?per_page=10"

    init() throws {
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
    }

    /// Stubs GitHub with `versions` (newest first), each with a release.json and a zip.
    func publish(_ versions: [(tag: String, id: Int64, day: Int)]) throws {
        var releases: [[String: Any]] = []
        for v in versions {
            let zipURL = "https://downloads.test/\(v.tag).zip"
            let jsonURL = "https://downloads.test/\(v.tag)-release.json"
            let zip = try makeAddonZip(folders: ["Addon", "Addon_Options"], marker: v.tag, named: "\(v.tag).zip", in: makeTempDirectory())
            transport.stub(URL(string: zipURL)!, try Data(contentsOf: zip))
            let releaseJSON = #"{"releases":[{"filename":"Addon-\#(v.tag).zip","nolib":false,"metadata":[{"flavor":"forever","interface":16001}]}]}"#
            http.stub(jsonURL, body: Data(releaseJSON.utf8))
            releases.append([
                "id": v.id, "tag_name": v.tag, "name": v.tag, "draft": false, "prerelease": false,
                "published_at": "2026-10-\(String(format: "%02d", v.day))T12:00:00Z", "body": "Notes for \(v.tag)",
                "assets": [
                    ["id": v.id * 10, "name": "Addon-\(v.tag).zip", "state": "uploaded", "size": 100,
                     "content_type": "application/zip", "browser_download_url": zipURL],
                    ["id": v.id * 10 + 1, "name": "release.json", "state": "uploaded", "size": 100,
                     "content_type": "application/json", "browser_download_url": jsonURL],
                ],
            ])
        }
        http.stub(Self.releasesURL, body: try JSONSerialization.data(withJSONObject: releases))
    }

    func addOnsFile(_ path: String) -> URL {
        installRoot.appending(path: "Interface/AddOns/\(path)")
    }

    @Test func fullLifecycle() async throws {
        let installation = try await manager.addInstallation(at: installRoot)
        #expect(installation.flavor == .forever)

        // Install v1.
        try publish([("v1", 1, 1)])
        let installed = try await manager.install(Self.ref, into: installation)
        #expect(installed.version == "v1")
        #expect(Set(installed.folders) == ["Addon", "Addon_Options"])
        #expect(installed.changelog == "Notes for v1")
        #expect(try String(contentsOf: addOnsFile("Addon/Core.lua"), encoding: .utf8).contains("v1"))

        #expect(try await manager.checkForUpdates(in: installation)[Self.ref] == .upToDate)

        // v2 is published.
        try publish([("v2", 2, 2), ("v1", 1, 1)])
        guard case .available(let release) = try await manager.checkForUpdates(in: installation)[Self.ref] else {
            Issue.record("expected an update")
            return
        }
        #expect(release.version == "v2")

        var events: [OperationEvent] = []
        for await event in manager.update([], in: installation) { events.append(event) }
        let done = events.compactMap { if case .done(let addon) = $0 { addon } else { nil } }
        #expect(done.map(\.version) == ["v2"])
        #expect(done.first?.previousRelease?.version == "v1")
        #expect(try String(contentsOf: addOnsFile("Addon/Core.lua"), encoding: .utf8).contains("v2"))

        // Roll back to v1 from the cache; that pins it.
        try await manager.rollback(Self.ref, in: installation)
        let afterRollback = try #require(try await manager.installedAddons(in: installation).first)
        #expect(afterRollback.version == "v1")
        #expect(afterRollback.pinned)
        #expect(try String(contentsOf: addOnsFile("Addon/Core.lua"), encoding: .utf8).contains("v1"))

        // Pinned add-ons are skipped.
        var skipped: [String] = []
        for await event in manager.update([], in: installation) {
            if case .skipped(_, let reason) = event { skipped.append(reason) }
        }
        #expect(skipped == ["Pinned"])

        // Uninstall removes the folders and the record.
        try await manager.uninstall(Self.ref, from: installation)
        #expect(!FileManager.default.fileExists(atPath: addOnsFile("Addon").path(percentEncoded: false)))
        #expect(try await manager.installedAddons(in: installation).isEmpty)
    }

    @Test func lookupFindsRefsAndInstalledNames() async throws {
        let installation = try await manager.addInstallation(at: installRoot)
        #expect(try await manager.lookup("https://github.com/Test/Addon", in: installation) == [Self.ref])

        try publish([("v1", 1, 1)])
        try await manager.install(Self.ref, into: installation)
        #expect(try await manager.lookup("addon_options", in: installation) == [Self.ref])
    }

    @Test func rollbackWithoutHistoryFails() async throws {
        let installation = try await manager.addInstallation(at: installRoot)
        try publish([("v1", 1, 1)])
        try await manager.install(Self.ref, into: installation)
        await #expect(throws: AddonError.noRollbackAvailable(Self.ref)) {
            try await manager.rollback(Self.ref, in: installation)
        }
    }

    @Test func environmentTokenWinsOverKeychain() {
        let keychain = KeychainStore(service: "AddonKitTests-\(UUID().uuidString)")
        #expect(AddonManager.token(environment: ["GITHUB_TOKEN": "b", "ADDONS_GITHUB_TOKEN": "a"], keychain: keychain) == "a")
        #expect(AddonManager.token(environment: ["GITHUB_TOKEN": " b "], keychain: keychain) == "b")
        #expect(AddonManager.token(environment: [:], keychain: keychain) == nil)
    }
}

@Suite struct UpdateReleasesTests {
    @Test func emptyReleaseListDoesNothing() async throws {
        let root = try makeTempDirectory()
        let manager = AddonManager(
            directories: AppDirectories(root: root.appending(path: "AppData")),
            http: StubHTTPClient(),
            downloadTransport: StubDownloadTransport(),
            locator: InstallationLocator(baseFolders: [], findApps: { [] }),
            keychain: KeychainStore(service: "AddonKitTests-\(UUID().uuidString)"),
            environment: [:]
        )
        let installation = Installation(id: "test", root: root.appending(path: "wow/_classic_beta_"), flavor: .forever)
        var events: [OperationEvent] = []
        for await event in manager.update(releases: [], in: installation) { events.append(event) }
        #expect(events.isEmpty)
    }
}
