import Foundation
import Testing
@testable import AddonKit

func searchCatalogueFixture() throws -> [CatalogueEntry] {
    CatalogueCSV.entries(from: try fixtureData("search/addons.csv"))
}

func catalogueEntry(_ fullName: String, name: String? = nil, description: String? = nil, updated: TimeInterval? = nil) -> CatalogueEntry {
    CatalogueEntry(
        id: fullName, name: name ?? String(fullName.split(separator: "/").last!), fullName: fullName,
        url: URL(string: "https://github.com/\(fullName)")!, description: description,
        lastUpdated: updated.map { Date(timeIntervalSince1970: $0) }
    )
}

@Suite struct SearchTextTests {
    @Test func camelCaseTokenisation() {
        #expect(SearchText.tokens("BigWigs") == ["bigwigs", "big", "wigs"])
        #expect(SearchText.tokens("DeadlyBossMods") == ["deadlybossmods", "deadly", "boss", "mods"])
        #expect(SearchText.tokens("DBMVoice") == ["dbmvoice", "dbm", "voice"])
        #expect(SearchText.tokens("WeakAuras2") == ["weakauras2", "weak", "auras", "2"])
        #expect(SearchText.tokens("bagnon-ui_mods") == ["bagnon", "ui", "mods"])
        #expect(SearchText.tokens("oRA3") == ["ora3", "o", "ra", "3"])
    }

    @Test func foldingIgnoresCaseAndDiacritics() {
        #expect(SearchText.key("Ätherwind Façade") == "atherwindfacade")
    }
}

@Suite struct SearchIndexTests {
    let index: SearchIndex

    init() throws {
        index = SearchIndex(entries: try searchCatalogueFixture())
    }

    private func top(_ text: String, _ n: Int = 3) -> [String] {
        index.search(text, limit: n).map(\.fullName)
    }

    @Test func exactNameIsFirst() {
        #expect(top("bosswarnings").first == "example-boss/BossWarnings")
        #expect(top("BossWarnings").first == "example-boss/BossWarnings")
    }

    @Test func bagFindsBagAddons() {
        let results = top("bag")
        #expect(results.count == 3)
        for name in results {
            #expect(name.lowercased().contains("bag"), "\(name)")
        }
        // Word-prefix match inside a camelCase name.
        #expect(index.search("bag").contains { $0.fullName == "example-bags/TidyBags" })
        #expect(index.search("bags").contains { $0.fullName == "example-bags/TidyBags" })
    }

    @Test func bossFindsBossMods() {
        #expect(top("boss").contains("example-boss/BossWarnings"))
        // Description match ("other boss mods").
        #expect(index.search("boss").contains { $0.fullName == "tinkerbee/PauseBar" })
        #expect(top("boss mods").contains("deepdelve/DelveBossMods"))
    }

    @Test func camelCaseSubwordsMatch() {
        #expect(index.search("warnings").contains { $0.fullName == "example-boss/BossWarnings" })
        #expect(index.search("delve boss").first?.fullName == "deepdelve/DelveBossMods")
    }

    @Test func errorSack() {
        #expect(top("errorsack").first == "example-dev/ErrorSack")
        #expect(top("error").contains("example-dev/ErrorSack"))
    }

    @Test func emptyAndNonMatchingQueries() {
        #expect(index.search("").isEmpty)
        #expect(index.search("   --- ").isEmpty)
        #expect(index.search("zzqxnotathing").isEmpty)
    }

    @Test func ownerMatches() {
        #expect(index.search("cartograph").contains { $0.fullName == "cartograph/OpenMap" })
    }
}

/// `SearchAliases` names real add-ons, so these entries use those names under made-up owners,
/// next to look-alikes that match the alias text literally.
@Suite struct SearchAliasTests {
    let index = SearchIndex(entries: [
        catalogueEntry("alias-test/DeadlyBossMods", description: "Raid timers and warnings", updated: 5),
        catalogueEntry("alias-test/DBM-BarSkins", description: "Bar skins for boss mods", updated: 9),
        catalogueEntry("alias-test/DBMVoicePack", updated: 8),
        catalogueEntry("alias-test/BigWigs", description: "Boss encounter timers", updated: 4),
        catalogueEntry("alias-test/BigWigs_Plugins", updated: 7),
        catalogueEntry("alias-test/BwTimers", updated: 9),
        catalogueEntry("alias-test/WeakAuras2", description: "Custom auras and icons", updated: 3),
        catalogueEntry("alias-test/WaterTracker", updated: 9),
        catalogueEntry("alias-test/WardrobeHelper", updated: 8),
    ])

    private func top(_ text: String, _ n: Int = 3) -> [String] {
        index.search(text, limit: n).map(\.fullName)
    }

    @Test func dbmAliasFindsDeadlyBossMods() {
        #expect(top("dbm").contains("alias-test/DeadlyBossMods"))
        #expect(top("DBM").first == "alias-test/DeadlyBossMods")
        #expect(index.search("deadly boss").first?.fullName == "alias-test/DeadlyBossMods")
    }

    @Test func bwAliasFindsBigWigs() {
        #expect(top("bw").first == "alias-test/BigWigs")
    }

    @Test func aliasForWeakAuras() {
        #expect(top("wa").contains("alias-test/WeakAuras2"))
    }
}

@Suite struct SearchRankingTests {
    @Test func tiersOrderResults() {
        let index = SearchIndex(entries: [
            catalogueEntry("a/DescOnly", name: "Something", description: "a great bag helper", updated: 4),
            catalogueEntry("a/AllWords", name: "BetterBag", updated: 3),
            catalogueEntry("a/Prefix", name: "Bagnon", updated: 2),
            catalogueEntry("a/Exact", name: "Bag", updated: 1),
        ])
        #expect(index.search("bag").map(\.fullName) == ["a/Exact", "a/Prefix", "a/AllWords", "a/DescOnly"])
    }

    @Test func onlyLastWordIsPrefix() {
        let index = SearchIndex(entries: [catalogueEntry("BigWigsMods/BigWigs")])
        #expect(index.search("big wig").count == 1)
        #expect(index.search("bi wigs").isEmpty)
    }

    @Test func pluralTolerance() {
        let index = SearchIndex(entries: [catalogueEntry("x/BetterBags", description: "Bag replacement")])
        #expect(index.search("bags better").count == 1)
        #expect(index.search("bag better").count == 1)
    }

    @Test func diacriticFolding() {
        let index = SearchIndex(entries: [catalogueEntry("x/Ätherwind"), catalogueEntry("y/Cafe", description: "Café helper")])
        #expect(index.search("ather").count == 1)
        #expect(index.search("ÄTHER").count == 1)
        #expect(index.search("café").count == 1)
    }

    @Test func supportThenRecencyBreakTies() {
        let index = SearchIndex(entries: [
            catalogueEntry("a/BagOld", updated: 1),
            catalogueEntry("a/BagNew", updated: 5),
            catalogueEntry("a/BagNo", updated: 9),
            catalogueEntry("a/BagYes", updated: 0),
        ])
        let statuses: [String: SupportStatus] = [
            "a/BagYes": .supported(version: "1"),
            "a/BagNo": .unsupported,
            "a/BagOld": .needsDownload,
        ]
        let results = index.search("bag") { statuses[$0.identifier] }
        #expect(results.map(\.fullName) == ["a/BagYes", "a/BagNew", "a/BagOld", "a/BagNo"])
    }

    @Test func fullCatalogueQueriesAreFast() throws {
        let base = try searchCatalogueFixture()
        var entries: [CatalogueEntry] = []
        for i in 0..<40 {
            entries += base.map { var e = $0; e.fullName = "\(e.fullName)\(i)"; return e }
        }
        let start = ContinuousClock.now
        let index = SearchIndex(entries: entries)
        let built = ContinuousClock.now
        for query in ["bag", "boss mods", "dbm", "weak", "quest helper", "x"] {
            _ = index.search(query)
        }
        let queried = ContinuousClock.now
        #expect(entries.count == 2_440)
        #expect(built - start < budget(.seconds(1)))
        #expect((queried - built) / 6 < budget(.milliseconds(50)))
    }

    @Test func recentlyUpdated() {
        let index = SearchIndex(entries: [catalogueEntry("a/A", updated: 1), catalogueEntry("a/B", updated: 3), catalogueEntry("a/C")])
        #expect(index.recentlyUpdated(limit: 5).map(\.fullName) == ["a/B", "a/A"])
    }
}
