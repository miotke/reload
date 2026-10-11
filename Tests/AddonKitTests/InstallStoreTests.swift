import Foundation
import Testing
@testable import AddonKit

private func makeAddon(_ identifier: String, folders: [String], name: String? = nil) -> InstalledAddon {
    InstalledAddon(
        id: AddonRef(source: .github, identifier: identifier), name: name ?? identifier, folders: folders,
        version: "v1", releaseID: 42, assetName: "a.zip",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000.25), installedAt: Date(timeIntervalSince1970: 1_700_000_100.5),
        channel: .prerelease, pinned: true, etag: "W/\"e\""
    )
}

private func makeInstallation(in tmp: URL, id: String = "abc123") throws -> Installation {
    let root = tmp.appending(path: "WoW/_classic_beta_", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root.appending(path: "Interface/AddOns"), withIntermediateDirectories: true)
    return Installation(id: id, root: root, flavor: .forever, productCode: "wow_classic_beta", gameVersion: "1.60.1.70338")
}

@Suite struct InstallStoreTests {
    @Test func crudRoundTrip() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = InstallStore(directories: AppDirectories(root: tmp))
        #expect(store.storeDirectory == tmp.appending(path: "Application Support/installations", directoryHint: .isDirectory))
        #expect(try await store.installations().isEmpty)

        let installation = try makeInstallation(in: tmp)
        try await store.save(installation)
        #expect(try await store.installations() == [installation])
        #expect(try await store.addons(in: installation).isEmpty)

        let a = makeAddon("Owner/A", folders: ["A"])
        var b = makeAddon("Owner/B", folders: ["B", "B_Options"])
        try await store.upsert(b, in: installation)
        try await store.upsert(a, in: installation)
        #expect(try await store.addons(in: installation) == [a, b])

        b.version = "v2"
        try await store.upsert(b, in: installation)
        #expect(try await store.addons(in: installation) == [a, b])

        // Saving the installation again keeps its add-ons.
        var renamed = installation
        renamed.gameVersion = "1.60.2.1"
        try await store.save(renamed)
        #expect(try await store.addons(in: renamed).count == 2)
        #expect(try await store.installations().first?.gameVersion == "1.60.2.1")

        try await store.remove(ref: a.id, in: installation)
        try await store.remove(ref: a.id, in: installation)
        #expect(try await store.addons(in: installation) == [b])

        // A fresh instance reads the same data from disk.
        let reopened = InstallStore(directories: AppDirectories(root: tmp))
        #expect(try await reopened.addons(in: installation) == [b])

        try await store.remove(installationID: installation.id)
        #expect(try await store.installations().isEmpty)
        #expect(try await store.addons(in: installation).isEmpty)
    }

    @Test func fileFormat() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = InstallStore(directories: AppDirectories(root: tmp))
        let installation = try makeInstallation(in: tmp)
        try await store.upsert(makeAddon("Owner/A", folders: ["A"]), in: installation)

        let url = store.storeDirectory.appending(path: "abc123.json")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect((json["installation"] as? [String: Any])?["id"] as? String == "abc123")
        let addon = try #require((json["addons"] as? [[String: Any]])?.first)
        #expect(addon["publishedAt"] as? String == "2023-11-14T22:13:20.250Z")
    }

    @Test func rejectsNewerSchemaAndSkipsCorruptFilesInListing() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = InstallStore(directories: AppDirectories(root: tmp))
        let installation = try makeInstallation(in: tmp, id: "future")
        try FileManager.default.createDirectory(at: store.storeDirectory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 2, "installation": {}, "addons": []}"#.utf8).write(to: store.storeDirectory.appending(path: "future.json"))
        try Data("garbage".utf8).write(to: store.storeDirectory.appending(path: "corrupt.json"))

        await #expect(throws: InstallStoreError.unsupportedSchemaVersion(2, file: "future.json")) {
            try await store.addons(in: installation)
        }
        #expect(try await store.installations().isEmpty)
    }

    @Test func concurrentUpsertsFromTwoStoresLoseNothing() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let first = InstallStore(directories: AppDirectories(root: tmp))
        let second = InstallStore(directories: AppDirectories(root: tmp))
        let installation = try makeInstallation(in: tmp)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                let store = i.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await store.upsert(makeAddon("Owner/Addon\(i)", folders: ["Addon\(i)"]), in: installation)
                }
            }
            try await group.waitForAll()
        }
        let ids = Set(try await first.addons(in: installation).map(\.id.identifier))
        #expect(ids == Set((0..<40).map { "Owner/Addon\($0)" }))
    }

    @Test func withLockIsReentrantAndModifyIsAtomic() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = InstallStore(directories: AppDirectories(root: tmp))
        let other = InstallStore(directories: AppDirectories(root: tmp))
        let installation = try makeInstallation(in: tmp)
        try await store.upsert(makeAddon("Owner/A", folders: ["A"]), in: installation)

        let count = try await store.withLock { store in
            try store.upsert(makeAddon("Owner/B", folders: ["B"]), in: installation)
            return try store.addons(in: installation).count
        }
        #expect(count == 2)

        // Concurrent read-modify-writes from two stores: every increment lands.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                let s = i.isMultiple(of: 2) ? store : other
                group.addTask {
                    try await s.modify(installation) { addons in
                        addons[0].releaseID += 1
                    }
                }
            }
            try await group.waitForAll()
        }
        let first = try #require(try await store.addons(in: installation).first)
        #expect(first.releaseID == 62)
    }

    @Test func reconcile() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = InstallStore(directories: AppDirectories(root: tmp))
        let installation = try makeInstallation(in: tmp)
        let fm = FileManager.default
        func folder(_ name: String, files: [String: String] = [:]) throws {
            let dir = installation.addonsDirectory.appending(path: name, directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (file, contents) in files { try Data(contents.utf8).write(to: dir.appending(path: file)) }
        }

        let managed = makeAddon("Owner/Managed", folders: ["Managed", "Managed_Gone"], name: "Managed")
        try await store.upsert(managed, in: installation)
        try folder("Managed")
        try folder("Blizzard_UI")
        try folder(".hidden")
        try Data().write(to: installation.addonsDirectory.appending(path: "stray.txt"))
        try folder("BigWigs", files: [
            "BigWigs_Mainline.toc": "## Title: Wrong\n",
            "BigWigs.toc": "## Title: BigWigs\n## X-Website: https://github.com/BigWigsMods/BigWigs/releases\n",
        ])
        try folder("Details", files: ["Details_Camelot.toc": "## Title: Details\n## X-Website: www.github.com/Tercioo/Details-Damage-Meter.git\n"])
        try folder("NoToc", files: ["readme.txt": "hi"])
        try folder("WebOnly", files: ["WebOnly.toc": "## X-Website: https://www.curseforge.com/wow/addons/webonly\n"])

        let statuses = try await store.reconcile(installation)
        #expect(statuses.count == 5)
        #expect(statuses[0] == .managed(managed, missingFolders: ["Managed_Gone"]))

        guard case .unmanaged(let bwFolder, let bwToc, let bwRef) = statuses[1] else { Issue.record("expected unmanaged"); return }
        #expect(bwFolder == "BigWigs")
        #expect(bwToc?.title == "BigWigs")
        #expect(bwRef == AddonRef(source: .github, identifier: "BigWigsMods/BigWigs"))

        guard case .unmanaged(let dFolder, let dToc, let dRef) = statuses[2] else { Issue.record("expected unmanaged"); return }
        #expect(dFolder == "Details")
        #expect(dToc?.title == "Details")
        #expect(dRef == AddonRef(source: .github, identifier: "Tercioo/Details-Damage-Meter"))

        #expect(statuses[3] == .unmanaged(folder: "NoToc", toc: nil, suggestedRef: nil))
        guard case .unmanaged("WebOnly", .some, nil) = statuses[4] else { Issue.record("unexpected \(statuses[4])"); return }
    }

    @Test func reconcileWithoutAddOnsFolder() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = InstallStore(directories: AppDirectories(root: tmp))
        let installation = Installation(id: "x", root: tmp.appending(path: "missing"), flavor: .forever)
        #expect(try await store.reconcile(installation).isEmpty)
    }

    @Test(arguments: [
        ("https://github.com/Owner/Repo", "Owner/Repo"),
        ("http://github.com/Owner/Repo/tree/main", "Owner/Repo"),
        ("github.com/Owner/repo.name", "Owner/repo.name"),
        ("https://gitlab.com/Owner/Repo", nil),
        ("https://github.com/Owner", nil),
    ] as [(String, String?)])
    func githubRefFromWebsite(website: String, expected: String?) {
        #expect(InstallStore.githubRef(fromWebsite: website)?.identifier == expected)
    }
}
