import Foundation
import Testing
@testable import AddonKit

/// A fake `World of Warcraft` folder in a temp dir.
private struct FakeWoW {
    let base: URL
    let wow: URL

    init(name: String = "World of Warcraft") throws {
        base = try makeTempDirectory()
        wow = base.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wow, withIntermediateDirectories: true)
    }

    func buildInfo(_ rows: [(product: String, version: String)]) throws {
        var text = "Branch!STRING:0|Active!DEC:1|Version!STRING:0|Product!STRING:0\n## seqn = 1\n"
        for row in rows { text += "us|1|\(row.version)|\(row.product)\n" }
        try Data(text.utf8).write(to: wow.appending(path: ".build.info"))
    }

    @discardableResult
    func flavorFolder(_ name: String, app: String? = nil, interface: Bool = true) throws -> URL {
        let root = wow.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if interface {
            try FileManager.default.createDirectory(at: root.appending(path: "Interface/AddOns"), withIntermediateDirectories: true)
        }
        if let app {
            try FileManager.default.createDirectory(at: root.appending(path: "\(app)/Contents"), withIntermediateDirectories: true)
        }
        return root
    }

    /// The real path (temp dirs live behind the `/var` → `/private/var` symlink).
    func resolved(_ url: URL) -> URL { InstallationLocator.resolve(url) }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }
}

@Suite struct InstallationLocatorTests {
    @Test func detectsForeverFromBuildInfo() throws {
        let fake = try FakeWoW()
        defer { fake.cleanUp() }
        try fake.buildInfo([("wow", "12.0.1.60000"), ("wow_classic_beta", "1.60.1.70338")])
        let root = try fake.flavorFolder("_classic_beta_")

        let locator = InstallationLocator(baseFolders: [], findApps: { [] })
        let installation = try locator.installation(at: root)
        #expect(installation.flavor == .forever)
        #expect(installation.productCode == "wow_classic_beta")
        #expect(installation.gameVersion == "1.60.1.70338")
        #expect(installation.root == fake.resolved(root))
        #expect(installation.id == InstallationLocator.installationID(for: root))
        #expect(installation.id.count == 16)
    }

    @Test func versionInBuildInfoWinsOverSubfolderName() throws {
        let fake = try FakeWoW()
        defer { fake.cleanUp() }
        // If the beta folder ever hosts a different game version, trust .build.info.
        try fake.buildInfo([("wow_classic_beta", "5.5.1.60000")])
        let root = try fake.flavorFolder("_classic_beta_")
        let installation = try InstallationLocator(baseFolders: [], findApps: { [] }).installation(at: root)
        #expect(installation.flavor == .mists)
    }

    @Test(arguments: [
        ("_retail_", "wow", "12.1.0.65000", Flavor.mainline),
        ("_ptr_", "wowt", "12.1.5.66000", .mainline),
        ("_beta_", "wow_beta", "13.0.0.67000", .mainline),
        ("_classic_", "wow_classic", "5.5.1.63000", .mists),
        ("_classic_era_", "wow_classic_era", "1.15.8.63829", .vanilla),
        ("_anniversary_", "wow_anniversary", "2.5.5.64001", .tbc),
        ("_classic_beta_", "wow_classic_beta", "1.60.1.70338", .forever),
        // `_classic_` moves on with each re-release; the version, not the folder, decides.
        ("_classic_", "wow_classic", "4.4.2.60000", .cata),
        ("_classic_", "wow_classic", "3.80.0.61000", .titan),
        ("_classic_beta_", "wow_classic_beta", "3.4.5.62000", .wrath),
    ])
    func detectsEachKnownProductFromBuildInfo(folder: String, product: String, version: String, flavor: Flavor) throws {
        let fake = try FakeWoW()
        defer { fake.cleanUp() }
        try fake.buildInfo([("wow", "12.1.0.65000"), (product, version)])
        let installation = try InstallationLocator(baseFolders: [], findApps: { [] }).installation(at: fake.flavorFolder(folder))
        #expect(installation.flavor == flavor)
        #expect(installation.productCode == product)
        #expect(installation.gameVersion == version)
    }

    @Test func subfolderFallbackForEachClassicFolder() throws {
        let fake = try FakeWoW()
        defer { fake.cleanUp() }
        let locator = InstallationLocator(baseFolders: [], findApps: { [] })
        #expect(try locator.installation(at: fake.flavorFolder("_classic_")).flavor == .mists)
        #expect(try locator.installation(at: fake.flavorFolder("_classic_era_")).flavor == .vanilla)
        #expect(try locator.installation(at: fake.flavorFolder("_anniversary_")).flavor == .tbc)
    }

    @Test func fallsBackToSubfolderNameWithoutBuildInfo() throws {
        let fake = try FakeWoW()
        defer { fake.cleanUp() }
        let locator = InstallationLocator(baseFolders: [], findApps: { [] })
        let beta = try locator.installation(at: fake.flavorFolder("_classic_beta_"))
        #expect(beta.flavor == .forever)
        #expect(beta.productCode == "wow_classic_beta")
        #expect(beta.gameVersion == nil)
        #expect(try locator.installation(at: fake.flavorFolder("_retail_")).flavor == .mainline)
        #expect(throws: AddonError.self) { try locator.installation(at: fake.flavorFolder("_mystery_")) }
    }

    @Test func flavorInfoSuppliesProductForUnknownSubfolder() throws {
        let fake = try FakeWoW()
        defer { fake.cleanUp() }
        try fake.buildInfo([("wow_forever", "1.61.0.80000")])
        let root = try fake.flavorFolder("_forever_")
        try Data("Product Flavor!STRING:0\nwow_forever\n".utf8).write(to: root.appending(path: ".flavor.info"))
        let installation = try InstallationLocator(baseFolders: [], findApps: { [] }).installation(at: root)
        #expect(installation.flavor == .forever)
        #expect(installation.productCode == "wow_forever")
        #expect(installation.gameVersion == "1.61.0.80000")
    }

    @Test func acceptsAddOnsPathAndWoWFolder() throws {
        let fake = try FakeWoW()
        defer { fake.cleanUp() }
        let root = try fake.flavorFolder("_classic_beta_")
        let locator = InstallationLocator(baseFolders: [], findApps: { [] })
        let expected = try locator.installation(at: root)

        #expect(try locator.installation(at: root.appending(path: "Interface/AddOns")) == expected)
        #expect(try locator.installation(at: root.appending(path: "Interface/AddOns/")) == expected)
        #expect(try locator.installation(at: fake.wow) == expected)

        try fake.flavorFolder("_retail_")
        #expect(throws: AddonError.installationNotFound(fake.resolved(fake.wow).path)) { try locator.installation(at: fake.wow) }
        #expect(throws: AddonError.self) { try locator.installation(at: fake.base.appending(path: "nope")) }
    }

    @Test func locateCombinesSpotlightAndBaseFolder() async throws {
        let base = try FakeWoW()
        defer { base.cleanUp() }
        try base.buildInfo([("wow_classic_beta", "1.60.1.70338"), ("wow", "12.0.1.1")])
        try base.flavorFolder("_classic_beta_")
        try base.flavorFolder("_retail_", interface: false) // no Interface, no .app → ignored
        try base.flavorFolder("_classic_era_", app: "World of Warcraft Classic.app", interface: false)
        try base.flavorFolder("Data", interface: true)       // not `_*_`

        // A second install elsewhere, only known through Spotlight.
        let other = try FakeWoW(name: "Games/WoW")
        defer { other.cleanUp() }
        let otherRoot = try other.flavorFolder("_retail_", app: "World of Warcraft.app", interface: false)
        let app = otherRoot.appending(path: "World of Warcraft.app")
        // Spotlight also reports an app we already know via the base folder.
        let duplicateApp = base.wow.appending(path: "_classic_era_/World of Warcraft Classic.app")

        let locator = InstallationLocator(baseFolders: [base.wow, base.base.appending(path: "missing")], findApps: { [app, duplicateApp] })
        let found = await locator.locate()
        let summary = found.map { "\($0.root.lastPathComponent):\($0.flavor.rawValue)" }
        #expect(Set(summary) == ["_classic_beta_:forever", "_classic_era_:vanilla", "_retail_:mainline"])
        #expect(found.count == 3)
        #expect(Set(found.map(\.id)).count == 3)
        #expect(found.contains { $0.root == base.resolved(otherRoot) })
    }

    @Test func installationIDIsStableAcrossSpellings() throws {
        let fake = try FakeWoW()
        defer { fake.cleanUp() }
        let root = try fake.flavorFolder("_classic_beta_")
        let a = InstallationLocator.installationID(for: root)
        let b = InstallationLocator.installationID(for: URL(filePath: root.path + "/Interface/../"))
        let c = InstallationLocator.installationID(for: fake.resolved(root))
        #expect(a == b && b == c)
        #expect(a.allSatisfy { $0.isHexDigit })
        #expect(a != InstallationLocator.installationID(for: fake.wow))
    }

    @Test func parsesSpotlightOutput() {
        let output = "/Applications/World of Warcraft/_classic_beta_/World of Warcraft Classic.app\n\n/Volumes/Games/WoW/_retail_/World of Warcraft.app\nnot a path\n"
        #expect(InstallationLocator.parseSpotlightOutput(output).map(\.lastPathComponent) == ["World of Warcraft Classic.app", "World of Warcraft.app"])
    }

    @Test func runProcessTimesOut() async {
        let start = ContinuousClock.now
        let output = await InstallationLocator.runProcess(URL(filePath: "/bin/sleep"), arguments: ["10"], timeout: 0.2)
        #expect(output.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
