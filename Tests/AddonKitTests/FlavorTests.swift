import Foundation
import Testing
@testable import AddonKit

@Suite struct FlavorRangeTests {
    @Test func noTwoFlavorsShareAnInterface() {
        let ranges = Flavor.allCases.flatMap { flavor in flavor.rules.interfaceRanges.map { (flavor, $0) } }
        for (i, a) in ranges.enumerated() {
            for b in ranges[(i + 1)...] {
                #expect(!a.1.overlaps(b.1), "\(a.0) \(a.1) overlaps \(b.0) \(b.1)")
            }
        }
    }

    @Test func everyVersionFromOnePointOhUpBelongsToExactlyOneFlavor() {
        for interface in 1_00_00...13_00_00 {
            let owners = Flavor.allCases.filter { $0.rules.contains(interface: interface) }
            if owners.count != 1 {
                Issue.record("interface \(interface) belongs to \(owners)")
                return
            }
        }
    }

    @Test(arguments: [
        // Ends of each range, and the versions just outside them.
        (1_12_01, Flavor.mainline), (1_13_00, .vanilla), (1_15_08, .vanilla), (1_59_99, .vanilla),
        (1_60_00, .forever), (1_60_01, .forever), (1_99_99, .forever), (2_00_00, .mainline),
        (2_04_03, .mainline), (2_05_00, .tbc), (2_05_05, .tbc), (2_99_99, .tbc),
        (3_03_05, .mainline), (3_04_00, .wrath), (3_04_05, .wrath), (3_79_99, .wrath),
        (3_80_00, .titan), (3_80_01, .titan), (3_99_99, .titan),
        (4_03_04, .mainline), (4_04_00, .cata), (4_04_02, .cata), (4_99_99, .cata),
        (5_04_08, .mainline), (5_05_00, .mists), (5_05_01, .mists), (5_99_99, .mists),
        (6_00_00, .mainline), (11_02_07, .mainline), (12_01_00, .mainline),
    ])
    func interfaceMapsToFlavor(interface: Int, flavor: Flavor) {
        #expect(Flavor.from(interface: interface) == flavor)
    }

    @Test(arguments: [
        ("1.15.8.63829", Flavor.vanilla), ("1.60.1.70338", .forever), ("1.61.0", .forever),
        ("2.5.5.64001", .tbc), ("3.4.5", .wrath), ("3.80.0.123", .titan), ("4.4.2", .cata),
        ("5.5.1.63000", .mists), ("12.1.0.65000", .mainline), ("1.12.1", .mainline),
    ])
    func gameVersionMapsToFlavor(version: String, flavor: Flavor) {
        #expect(Flavor.from(gameVersion: version) == flavor)
    }

    @Test func unparsableVersionsMapToNothing() {
        #expect(Flavor.from(gameVersion: "beta") == nil)
        #expect(Flavor.from(gameVersion: "") == nil)
        #expect(Flavor.from(interface: 0) == nil)
    }

    @Test func displayNames() {
        #expect(Flavor.allCases.map(\.displayName) == [
            "Retail", "Forever", "Classic Era", "TBC Anniversary", "Wrath Classic", "Titan", "Cata Classic", "Mists Classic",
        ])
    }

    @Test func productsAndSubfolders() {
        #expect(Flavor.from(productCode: "wow") == .mainline)
        #expect(Flavor.from(productCode: "wowt") == .mainline)
        #expect(Flavor.from(productCode: "wow_beta") == .mainline)
        #expect(Flavor.from(productCode: "wow_classic") == .mists)
        #expect(Flavor.from(productCode: "wow_classic_era") == .vanilla)
        #expect(Flavor.from(productCode: "wow_anniversary") == .tbc)
        #expect(Flavor.from(productCode: "wow_classic_beta") == .forever)
        #expect(Flavor.from(subfolder: "_Classic_Era_") == .vanilla)
        #expect(Flavor.from(subfolder: "_mystery_") == nil)
    }

    @Test func legacyClassicInstallationDecodesFromItsGameVersion() throws {
        let json = #"{"id":"a","root":"file:///wow/_classic_era_/","flavor":"classic","productCode":"wow_classic_era","gameVersion":"1.15.8.1"}"#
        #expect(try JSONDecoder().decode(Installation.self, from: Data(json.utf8)).flavor == .vanilla)
        let noVersion = #"{"id":"a","root":"file:///wow/_classic_/","flavor":"classic","productCode":"wow_classic"}"#
        #expect(try JSONDecoder().decode(Installation.self, from: Data(noVersion.utf8)).flavor == .mists)
        let unknown = #"{"id":"a","root":"file:///wow/_x_/","flavor":"classic"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Installation.self, from: Data(unknown.utf8)) }
        let forever = try JSONEncoder().encode(Installation(id: "f", root: URL(filePath: "/wow/_classic_beta_"), flavor: .forever))
        #expect(try JSONDecoder().decode(Installation.self, from: forever).flavor == .forever)
    }
}

@Suite struct FlavorTocTests {
    @Test(arguments: [
        ("A_Mainline.toc", Flavor.mainline), ("A_Camelot.toc", .forever), ("A-Forever.toc", .forever),
        ("A_Vanilla.toc", .vanilla), ("A_TBC.toc", .tbc), ("A-BCC.toc", .tbc), ("A_Wrath.toc", .wrath),
        ("A_WOTLKC.toc", .wrath), ("A_Cata.toc", .cata), ("A_Mists.toc", .mists),
    ])
    func specificSuffix(file: String, flavor: Flavor) throws {
        let name = try #require(TocFileName(file))
        #expect(name.addonName == "A")
        #expect(Flavor.allCases.filter { name.isSpecific(to: $0) } == [flavor])
    }

    @Test func classicIsSharedByEveryClassic() throws {
        let name = try #require(TocFileName("A_Classic.toc"))
        #expect(name.suffix == "Classic")
        #expect(Flavor.allCases.filter { name.isSpecific(to: $0) }.isEmpty)
        #expect(Flavor.allCases.filter { name.isShared(for: $0) } == [.vanilla, .tbc, .wrath, .titan, .cata, .mists])
    }

    @Test(arguments: Flavor.allCases)
    func specificTocSettlesSupport(flavor: Flavor) throws {
        guard let suffix = flavor.rules.tocSuffixes.first else { return }
        let zip = try makeInspectorZip(["A/A_\(suffix).toc": "## Interface: 1", "A/A.toc": "## Interface: 1"])
        let result = try ZipInspector.inspect(zipAt: zip, flavor: flavor)
        #expect(result.isSupported)
        #expect(result.matchedToc == "A/A_\(suffix).toc")
    }

    /// One packager zip: per-game TOCs, with `_Classic` covering Mists.
    @Test func multiGameZipGoesToTheRightToc() throws {
        let zip = try makeInspectorZip([
            "A/A.toc": "## Interface: 120100",
            "A/A_Camelot.toc": "## Interface: 16001",
            "A/A_Vanilla.toc": "## Interface: 11508",
            "A/A_TBC.toc": "## Interface: 20505",
            "A/A_Classic.toc": "## Interface: 50501",
        ])
        let matched = try Flavor.allCases.map { try ZipInspector.inspect(zipAt: zip, flavor: $0).matchedToc }
        #expect(matched == ["A/A.toc", "A/A_Camelot.toc", "A/A_Vanilla.toc", "A/A_TBC.toc", nil, nil, nil, "A/A_Classic.toc"])
    }

    @Test func classicFallbackRespectsTheInterfaceRange() throws {
        let zip = try makeInspectorZip(["A/A_Classic.toc": "## Interface: 11508, 50501", "A/A.toc": "## Interface: 40402"])
        #expect(try ZipInspector.supports(.vanilla, zipAt: zip))
        #expect(try ZipInspector.supports(.mists, zipAt: zip))
        // Cata loads `_Classic` before the base TOC, and it lists no Cata interface.
        #expect(try !ZipInspector.supports(.cata, zipAt: zip))
        #expect(try !ZipInspector.supports(.tbc, zipAt: zip))
        #expect(try !ZipInspector.supports(.forever, zipAt: zip))
        #expect(try !ZipInspector.supports(.mainline, zipAt: zip))
    }

    @Test func titanUsesWrathTocsOnlyWithATitanInterface() throws {
        let wrathOnly = try makeInspectorZip(["A/A_Wrath.toc": "## Interface: 30405"])
        #expect(try ZipInspector.supports(.wrath, zipAt: wrathOnly))
        #expect(try !ZipInspector.supports(.titan, zipAt: wrathOnly))
        let both = try makeInspectorZip(["A/A_Wrath.toc": "## Interface: 30405, 38000", "A/A_Classic.toc": "## Interface: 11508"])
        let titan = try ZipInspector.inspect(zipAt: both, flavor: .titan)
        #expect(titan.isSupported)
        #expect(titan.matchedToc == "A/A_Wrath.toc")
    }

    @Test func baseTocWorksOnlyForTheFlavorItsInterfaceIsIn() throws {
        for flavor in Flavor.allCases {
            let interface = flavor.rules.interfaceRanges.last!.lowerBound
            let zip = try makeInspectorZip(["A/A.toc": "## Interface: \(interface)"])
            #expect(try Flavor.allCases.filter { try ZipInspector.supports($0, zipAt: zip) } == [flavor])
        }
    }
}

@Suite struct FlavorReleaseJSONTests {
    @Test(arguments: [
        ("mainline", Flavor.mainline), ("retail", .mainline), ("forever", .forever), ("camelot", .forever),
        ("classic", .vanilla), ("vanilla", .vanilla), ("bcc", .tbc), ("tbc", .tbc), ("wrath", .wrath),
        ("titan", .titan), ("cata", .cata), ("mists", .mists),
    ])
    func packagerFlavorNames(name: String, flavor: Flavor) {
        let release = ReleaseJSON.Release(filename: "A.zip", nolib: false, metadata: [.init(flavor: name, interface: 1)])
        #expect(Flavor.allCases.filter { release.supports($0) } == [flavor])
    }

    @Test func separateBuildsGoToTheirOwnGames() {
        let json = ghReleaseJSON([
            ("A-v1.zip", false, [("mainline", 120100), ("forever", 16001)]),
            ("A-v1-classic.zip", false, [("classic", 11508)]),
            ("A-v1-mists.zip", false, [("mists", 50501)]),
        ])
        let assets = [ghAsset(1, "A-v1.zip"), ghAsset(2, "A-v1-classic.zip"), ghAsset(3, "A-v1-mists.zip"), ghAsset(4, "release.json")]
        let release = ghRelease(10, tag: "v1", assets: assets)
        func picked(_ flavor: Flavor) -> String? {
            guard case .selected(_, let asset, _) = ReleaseSelector.select([release], channel: .stable, flavor: flavor, releaseJSONs: [4: json]) else { return nil }
            return asset.name
        }
        #expect(picked(.mists) == "A-v1-mists.zip")
        #expect(picked(.vanilla) == "A-v1-classic.zip")
        #expect(picked(.forever) == "A-v1.zip")
        #expect(picked(.mainline) == "A-v1.zip")
        #expect(picked(.tbc) == nil)
        #expect(picked(.titan) == nil)
    }

    @Test func zipCandidatesPreferTheFlavorsName() {
        let release = ghRelease(10, tag: "v1", assets: [ghAsset(1, "A-v1.zip"), ghAsset(2, "A-v1-mists.zip"), ghAsset(3, "A-v1-classic.zip")])
        #expect(ReleaseSelector.zipCandidates(release, flavor: .mists).map(\.name) == ["A-v1-mists.zip", "A-v1.zip", "A-v1-classic.zip"])
        #expect(ReleaseSelector.zipCandidates(release, flavor: .vanilla).first?.name == "A-v1-classic.zip")
    }
}
