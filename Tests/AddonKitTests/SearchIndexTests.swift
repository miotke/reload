import Foundation
import Testing
@testable import AddonKit

func catalogueFixture() throws -> [CatalogueEntry] {
    CatalogueCSV.entries(from: try fixtureData("search/addons.csv"))
}

func entry(_ fullName: String, name: String? = nil, description: String? = nil, updated: TimeInterval? = nil) -> CatalogueEntry {
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
        index = SearchIndex(entries: try catalogueFixture())
    }

    private func top(_ text: String, _ n: Int = 3) -> [String] {
        index.search(text, limit: n).map(\.fullName)
    }

    @Test func dbmAliasFindsDeadlyBossMods() {
        #expect(top("dbm").contains("DeadlyBossMods/DeadlyBossMods"))
        #expect(top("DBM").first == "DeadlyBossMods/DeadlyBossMods")
    }

    @Test func bigwigsIsFirst() {
        #expect(top("bigwigs").first == "BigWigsMods/BigWigs")
        #expect(top("BigWigs").first == "BigWigsMods/BigWigs")
        #expect(top("bw").first == "BigWigsMods/BigWigs")
    }

    @Test func bagFindsBagAddons() {
        let results = top("bag")
        #expect(results.count == 3)
        for name in results {
            #expect(name.lowercased().contains("bag"), "\(name)")
        }
        // Word-prefix match inside a camelCase name.
        #expect(index.search("bag").contains { $0.fullName == "Cidan/BetterBags" })
        #expect(index.search("bags").contains { $0.fullName == "Cidan/BetterBags" })
    }

    @Test func bossFindsBossMods() {
        #expect(top("boss").contains("DeadlyBossMods/DeadlyBossMods"))
        // Description match ("beat any boss encounter").
        #expect(index.search("boss").contains { $0.fullName == "BigWigsMods/BigWigs" })
        #expect(top("boss mods").contains("DeadlyBossMods/DeadlyBossMods"))
    }

    @Test func camelCaseSubwordsMatch() {
        #expect(index.search("wigs").contains { $0.fullName == "BigWigsMods/BigWigs" })
        #expect(index.search("deadly boss").first?.fullName == "DeadlyBossMods/DeadlyBossMods")
    }

    @Test func aliasForWeakAuras() {
        #expect(top("wa").contains("WeakAuras/WeakAuras2"))
    }

    @Test func bugsack() {
        #expect(top("bugsack").first == "funkydude/BugSack")
        #expect(top("bug").contains("funkydude/BugSack"))
    }

    @Test func emptyAndNonMatchingQueries() {
        #expect(index.search("").isEmpty)
        #expect(index.search("   --- ").isEmpty)
        #expect(index.search("zzqxnotathing").isEmpty)
    }

    @Test func ownerMatches() {
        #expect(index.search("funkydude").contains { $0.fullName == "funkydude/BugSack" })
    }
}

@Suite struct SearchRankingTests {
    @Test func tiersOrderResults() {
        let index = SearchIndex(entries: [
            entry("a/DescOnly", name: "Something", description: "a great bag helper", updated: 4),
            entry("a/AllWords", name: "BetterBag", updated: 3),
            entry("a/Prefix", name: "Bagnon", updated: 2),
            entry("a/Exact", name: "Bag", updated: 1),
        ])
        #expect(index.search("bag").map(\.fullName) == ["a/Exact", "a/Prefix", "a/AllWords", "a/DescOnly"])
    }

    @Test func onlyLastWordIsPrefix() {
        let index = SearchIndex(entries: [entry("BigWigsMods/BigWigs")])
        #expect(index.search("big wig").count == 1)
        #expect(index.search("bi wigs").isEmpty)
    }

    @Test func pluralTolerance() {
        let index = SearchIndex(entries: [entry("x/BetterBags", description: "Bag replacement")])
        #expect(index.search("bags better").count == 1)
        #expect(index.search("bag better").count == 1)
    }

    @Test func diacriticFolding() {
        let index = SearchIndex(entries: [entry("x/Ätherwind"), entry("y/Cafe", description: "Café helper")])
        #expect(index.search("ather").count == 1)
        #expect(index.search("ÄTHER").count == 1)
        #expect(index.search("café").count == 1)
    }

    @Test func supportThenRecencyBreakTies() {
        let index = SearchIndex(entries: [
            entry("a/BagOld", updated: 1),
            entry("a/BagNew", updated: 5),
            entry("a/BagNo", updated: 9),
            entry("a/BagYes", updated: 0),
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
        let base = try catalogueFixture()
        var entries: [CatalogueEntry] = []
        for i in 0..<12 {
            entries += base.map { var e = $0; e.fullName = "\(e.fullName)\(i)"; return e }
        }
        let start = ContinuousClock.now
        let index = SearchIndex(entries: entries)
        let built = ContinuousClock.now
        for query in ["bag", "boss mods", "dbm", "weak", "quest helper", "x"] {
            _ = index.search(query)
        }
        let queried = ContinuousClock.now
        #expect(entries.count == 2400)
        #expect(built - start < .seconds(1))
        #expect((queried - built) / 6 < .milliseconds(50))
    }

    @Test func recentlyUpdated() {
        let index = SearchIndex(entries: [entry("a/A", updated: 1), entry("a/B", updated: 3), entry("a/C")])
        #expect(index.recentlyUpdated(limit: 5).map(\.fullName) == ["a/B", "a/A"])
    }
}
