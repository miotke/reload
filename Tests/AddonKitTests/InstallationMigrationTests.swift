import Foundation
import Testing
@testable import AddonKit

/// Forever moved from `_classic_beta_` to `_forever_` at launch: a stored installation whose
/// folder is gone hands its records to the one that replaced it.
@Suite struct InstallationMigrationTests {
    let base: URL
    let wow: URL
    let appData: URL

    init() throws {
        base = try makeTempDirectory()
        wow = base.appending(path: "World of Warcraft", directoryHint: .isDirectory)
        appData = base.appending(path: "AppData", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wow, withIntermediateDirectories: true)
    }

    /// A new manager each time, as each app launch or CLI run is a new process.
    func manager() -> AddonManager {
        AddonManager(
            directories: AppDirectories(root: appData),
            http: StubHTTPClient(),
            downloadTransport: StubDownloadTransport(),
            locator: InstallationLocator(baseFolders: [wow], findApps: { [] }),
            keychain: KeychainStore(service: "AddonKitTests-\(UUID().uuidString)"),
            environment: [:]
        )
    }

    func buildInfo(_ rows: [(product: String, version: String)]) throws {
        var text = "Branch!STRING:0|Active!DEC:1|Version!STRING:0|Product!STRING:0\n"
        for row in rows { text += "us|1|\(row.version)|\(row.product)\n" }
        try Data(text.utf8).write(to: wow.appending(path: ".build.info"))
    }

    @discardableResult
    func folder(_ name: String) throws -> URL {
        let root = wow.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Interface/AddOns/Spoken"), withIntermediateDirectories: true)
        return root
    }

    func storeBetaWithAddon() async throws -> Installation {
        try buildInfo([("wow_classic_beta", "1.60.1.70450")])
        try folder("_classic_beta_")
        let beta = try #require(try await manager().installations().first)
        let addon = InstalledAddon(
            id: AddonRef(source: .github, identifier: "Owner/Spoken"), name: "Spoken", folders: ["Spoken"],
            version: "v1", releaseID: 1, assetName: "s.zip", publishedAt: .now, installedAt: .now
        )
        try await InstallStore(directories: AppDirectories(root: appData)).upsert(addon, in: beta)
        return beta
    }

    func launch() throws {
        try FileManager.default.moveItem(at: wow.appending(path: "_classic_beta_"), to: wow.appending(path: "_forever_"))
        try buildInfo([("wowf", "1.60.1.70862")])
    }

    @Test func renamedFolderTakesOverRecords() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try await storeBetaWithAddon()
        try launch()

        let manager = manager()
        let installations = try await manager.installations()
        #expect(installations.count == 1)
        let forever = try #require(installations.first)
        #expect(forever.root.lastPathComponent == "_forever_")
        #expect(forever.flavor == .forever)
        #expect(forever.productCode == "wowf")
        #expect(forever.gameVersion == "1.60.1.70862")
        #expect(try await manager.installedAddons(in: forever).map(\.name) == ["Spoken"])
    }

    @Test func ambiguousReplacementKeepsBoth() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let beta = try await storeBetaWithAddon()
        try launch()
        try folder("_forever_ptr_")
        try Data("Product Flavor!STRING:0\nwowfptr\n".utf8).write(to: wow.appending(path: "_forever_ptr_/.flavor.info"))
        try buildInfo([("wowf", "1.60.1.70862"), ("wowfptr", "1.60.2.70900")])

        let installations = try await manager().installations()
        #expect(installations.count == 3)
        #expect(installations.contains { $0.id == beta.id })
    }

    @Test func presentFolderSkipsDetection() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try await storeBetaWithAddon()
        try folder("_retail_")
        try buildInfo([("wow_classic_beta", "1.60.1.70450"), ("wow", "12.0.1.1")])
        #expect(try await manager().installations().count == 1)
    }

    @Test func moveNeverOverwritesStoredRecords() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let beta = try await storeBetaWithAddon()
        let store = InstallStore(directories: AppDirectories(root: appData))
        let other = Installation(id: "other", root: wow.appending(path: "_forever_"), flavor: .forever)
        try await store.save(other)
        #expect(try await store.move(installationID: beta.id, to: other) == false)
        #expect(try await store.addons(in: beta).count == 1)
        #expect(try await store.addons(in: other).isEmpty)
    }
}
