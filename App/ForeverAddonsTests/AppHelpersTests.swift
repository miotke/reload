import AddonKit
import Foundation
import Testing

@Suite struct DayLabelTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    let locale = Locale(identifier: "en_US")

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func sameDayIsToday() {
        let now = date(2026, 10, 11, 23)
        #expect(DayLabel.string(for: date(2026, 10, 11, 0), now: now, calendar: calendar, locale: locale) == "Today")
        #expect(DayLabel.string(for: now.addingTimeInterval(-3), now: now, calendar: calendar, locale: locale) == "Today")
    }

    @Test func otherDaysShowTheDate() {
        let now = date(2026, 10, 11)
        #expect(DayLabel.string(for: date(2026, 10, 9), now: now, calendar: calendar, locale: locale) == "Oct 9, 2026")
        #expect(DayLabel.string(for: date(2026, 10, 10, 23), now: now, calendar: calendar, locale: locale) == "Oct 10, 2026")
        #expect(DayLabel.string(for: date(2023, 1, 2), now: now, calendar: calendar, locale: locale) == "Jan 2, 2023")
    }
}

@Suite struct LivePatchTests {
    func result(_ name: String, support: SupportStatus = .unknown) -> SearchResult {
        SearchResult(id: AddonRef(source: .github, identifier: "o/\(name)"), name: name, owner: "o",
                     support: support, origin: [.catalogue])
    }

    @Test func patchesOnlyChangedRefs() {
        let results = [result("A"), result("B", support: .needsDownload), result("C")]
        let patched = results.patching([
            AddonRef(source: .github, identifier: "o/A"): StoredAvailability(support: .supported(version: "1.0"), availableFlavors: [.forever]),
            AddonRef(source: .github, identifier: "o/C"): StoredAvailability(support: nil, availableFlavors: [.mainline]),
            AddonRef(source: .github, identifier: "o/Z"): StoredAvailability(support: .unsupported, availableFlavors: nil),
        ])
        #expect(patched.map(\.support) == [.supported(version: "1.0"), .needsDownload, .unknown])
        #expect(patched.map(\.availableFlavors) == [[.forever], nil, [.mainline]])
        #expect(patched.map(\.id) == results.map(\.id))
    }
}

@Suite struct TableSortingTests {
    func result(_ name: String, stars: Int? = nil, updated: Date? = nil, support: SupportStatus = .unknown,
                flavors: Set<Flavor>? = nil) -> BrowseRow {
        BrowseRow(SearchResult(id: AddonRef(source: .github, identifier: "o/\(name)"), name: name, owner: "o",
                               stars: stars, lastUpdated: updated, support: support, availableFlavors: flavors, origin: [.catalogue]),
                  flavor: .forever)
    }

    @Test func sortsByDateNotText() {
        let rows = [
            result("A", updated: Date(timeIntervalSince1970: 2_000)),
            result("B", updated: Date(timeIntervalSince1970: 3_000)),
            result("C", updated: Date(timeIntervalSince1970: 1_000)),
        ]
        #expect(rows.sorted(using: ColumnSort(BrowseColumn.updated)).map(\.name) == ["C", "A", "B"])
        #expect(rows.sorted(using: ColumnSort(BrowseColumn.updated, order: .reverse)).map(\.name) == ["B", "A", "C"])
    }

    @Test func missingValuesSortLastEitherWay() {
        let rows = [result("A", stars: 5), result("B"), result("C", stars: 50)]
        #expect(rows.sorted(using: ColumnSort(BrowseColumn.stars)).map(\.name) == ["A", "C", "B"])
        #expect(rows.sorted(using: ColumnSort(BrowseColumn.stars, order: .reverse)).map(\.name) == ["C", "A", "B"])
    }

    @Test func namesSortNaturallyAndTiesBreakByName() {
        let rows = [result("Addon10", stars: 1), result("addon9", stars: 1), result("Bags", stars: 1)]
        #expect(rows.sorted(using: ColumnSort(BrowseColumn.name)).map(\.name) == ["addon9", "Addon10", "Bags"])
        // Equal stars: name ascending even when the column is descending.
        #expect(rows.sorted(using: ColumnSort(BrowseColumn.stars, order: .reverse)).map(\.name) == ["addon9", "Addon10", "Bags"])
    }

    @Test func gamesSortByOwnFamilyThenCount() {
        let rows = [
            result("Retail", flavors: [.mainline]),
            result("Unchecked"),
            result("All", flavors: [.mainline, .forever, .mists]),
            result("Forever", flavors: [.forever]),
            result("RetailClassic", flavors: [.mainline, .vanilla]),
        ]
        #expect(rows.sorted(using: ColumnSort(BrowseColumn.games)).map(\.name) == ["All", "Forever", "RetailClassic", "Retail", "Unchecked"])
        #expect(rows.sorted(using: ColumnSort(BrowseColumn.games, order: .reverse)).map(\.name) == ["Retail", "RetailClassic", "Forever", "All", "Unchecked"])
        // The old support column's stored sort still parses.
        #expect(ColumnSort<BrowseColumn>(storageValue: "support.asc") == ColumnSort(.games))
    }

    @Test func storageRoundTrips() {
        let sort = ColumnSort(BrowseColumn.updated, order: .reverse)
        #expect(sort.storageValue == "updated.desc")
        #expect(ColumnSort<BrowseColumn>(storageValue: "updated.desc") == sort)
        #expect(ColumnSort<BrowseColumn>(storageValue: "") == nil)
        #expect(ColumnSort<BrowseColumn>(storageValue: "bogus.asc") == nil)
        #expect(ColumnSort<InstalledColumn>(storageValue: "version.asc") == ColumnSort(.version))
    }

    func installed(_ name: String, version: String, installedAt: Date = .now, pinned: Bool = false,
                   missing: [String] = [], update: UpdateState? = nil) -> InstalledRow {
        let addon = InstalledAddon(
            id: AddonRef(source: .github, identifier: "o/\(name)"), name: name, folders: [name], version: version,
            releaseID: 1, assetName: "a.zip", publishedAt: .now, installedAt: installedAt, pinned: pinned)
        return InstalledRow(status: .managed(addon, missingFolders: missing), update: update, flavor: .forever)
    }

    @Test func installedVersionsSortNumerically() {
        let rows = [installed("A", version: "1.10.0"), installed("B", version: "1.9.2"), installed("C", version: "1.2")]
        #expect(rows.sorted(using: ColumnSort(InstalledColumn.version)).map(\.name) == ["C", "B", "A"])
    }

    @Test func installedStatusPutsAttentionFirst() {
        let release = ResolvedRelease(ref: AddonRef(source: .github, identifier: "o/U"), name: "U", version: "2",
                                      releaseID: 2, publishedAt: .now, downloadURL: URL(string: "https://x")!, assetName: "a.zip")
        let rows = [
            installed("Fine", version: "1", update: .upToDate),
            installed("Pinned", version: "1", pinned: true, update: .available(release)),
            installed("U", version: "1", update: .available(release)),
            installed("Missing", version: "1", missing: ["Missing"]),
            installed("Unchecked", version: "1"),
        ]
        #expect(rows.sorted(using: ColumnSort(InstalledColumn.status)).map(\.name) == ["Missing", "U", "Pinned", "Fine", "Unchecked"])
        // A pinned add-on doesn't offer its update.
        #expect(rows[1].availableVersion == nil)
        #expect(rows[2].availableVersion == "2")
    }

    @Test func installedDatesSortByDate() {
        let rows = [
            installed("Old", version: "1", installedAt: Date(timeIntervalSince1970: 1_000)),
            installed("New", version: "1", installedAt: Date(timeIntervalSince1970: 9_000)),
        ]
        #expect(rows.sorted(using: ColumnSort(InstalledColumn.installed, order: .reverse)).map(\.name) == ["New", "Old"])
    }

    @Test func rowIDsRoundTripToRefs() {
        let ref = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs")
        #expect(AddonRef(rowID: ref.description) == ref)
        #expect(AddonRef(rowID: "unmanaged:Foo") == nil)
    }
}

@Suite struct MarkdownParserTests {
    @Test func headingsParagraphsAndLists() {
        let blocks = MarkdownParser.blocks(from: """
            # Title
            Some text
            continues here.

            ## Features
            - one
              more of one
            * two
            1. first
            - [x] done

            Setext
            ------
            """)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some text continues here."),
            .heading(level: 2, text: "Features"),
            .listItem(marker: "•", depth: 0, text: "one more of one"),
            .listItem(marker: "•", depth: 0, text: "two"),
            .listItem(marker: "1.", depth: 0, text: "first"),
            .listItem(marker: "☑", depth: 0, text: "done"),
            .heading(level: 2, text: "Setext"),
        ])
    }

    @Test func dropsImagesBadgesHTMLAndComments() {
        let blocks = MarkdownParser.blocks(from: """
            <p align="center"><img src="logo.png"></p>
            [![Build](https://img.shields.io/x.svg)](https://ci) ![shot](a.png)
            <!-- a
            comment -->
            Hello <b>world</b> and [link](https://example.com).
            """)
        #expect(blocks == [.paragraph("Hello world and [link](https://example.com).")])
    }

    @Test func codeQuotesTablesAndRules() {
        let blocks = MarkdownParser.blocks(from: """
            ```lua
            local x = 1
              -- # not a heading
            ```
            > quoted
            > text

            | Command | Does |
            |---|:--:|
            | /bw | opens |

            ---
            """)
        #expect(blocks == [
            .code("local x = 1\n  -- # not a heading"),
            .quote("quoted text"),
            .table([["Command", "Does"], ["/bw", "opens"]]),
            .rule,
        ])
    }

    @Test func unterminatedFenceKeepsCode() {
        #expect(MarkdownParser.blocks(from: "```\ncode") == [.code("code")])
    }
}

@Suite struct GameBubblesTests {
    let autoPotion: Set<Flavor> = [.mists, .mainline, .wrath, .cata, .vanilla, .tbc, .forever]

    @Test func autoPotionHasAllThree() throws {
        let model = GameBubblesModel(availableFlavors: autoPotion, flavor: .forever)
        let bubbles = try #require(model.bubbles)
        #expect(bubbles.map(\.family) == [.retail, .forever, .classic])
        #expect(bubbles.allSatisfy { $0.isPresent })
        #expect(bubbles.map(\.isOwn) == [false, true, false])
        #expect(bubbles[2].help == "Classic: Era, TBC Anniversary, Wrath, Cata, Mists")
        #expect(bubbles[1].help == "Forever build")
        #expect(model.accessibilityLabel == "Games: Retail, Forever, Classic")
        #expect(model.ownFamilyPresent && model.familyCount == 3)
    }

    @Test func retailOnlyOnForeverExplainsTheCheckbox() throws {
        let model = GameBubblesModel(availableFlavors: [.mainline, .vanilla], flavor: .forever)
        let bubbles = try #require(model.bubbles)
        #expect(bubbles.map(\.isPresent) == [true, false, true])
        #expect(bubbles[0].help == "Retail build: may work on Forever, which lists it as out of date until you tick Load out of date AddOns")
        #expect(bubbles[1].help == "No Forever build")
        #expect(bubbles[2].help == "Classic: Era")
        #expect(!model.ownFamilyPresent)
        // On Retail the R bubble is plain, and it's the installation's own.
        let retail = try #require(GameBubblesModel(availableFlavors: [.mainline], flavor: .mainline).bubbles)
        #expect(retail[0].help == "Retail build" && retail[0].isOwn)
    }

    @Test func notCheckedIsADash() {
        let model = GameBubblesModel(availableFlavors: nil, flavor: .forever)
        #expect(model.bubbles == nil && !model.isChecked)
        #expect(model.uncheckedHelp.hasPrefix("Not checked yet"))
        #expect(GameBubblesModel(availableFlavors: nil, flavor: .forever, support: .needsDownload).uncheckedHelp.contains("no release.json"))
        #expect(GameBubblesModel(availableFlavors: nil, flavor: .forever, support: .noReleases).uncheckedHelp == "This repository has no GitHub releases")
    }

    @Test func retailBuildIsOfferedOnlyWhenItHelps() {
        #expect(RetailBuildOffer.isOffered(availableFlavors: [.mainline], flavor: .forever))
        #expect(!RetailBuildOffer.isOffered(availableFlavors: [.mainline, .forever], flavor: .forever))
        #expect(!RetailBuildOffer.isOffered(availableFlavors: [.vanilla], flavor: .forever))
        #expect(!RetailBuildOffer.isOffered(availableFlavors: nil, flavor: .forever))
        #expect(!RetailBuildOffer.isOffered(availableFlavors: [.mainline], flavor: .mists))
        #expect(RetailBuildOffer.explanation(for: .forever).contains("Load out of date AddOns"))
    }

    @Test func browseRowsPrecomputeGamesAndDimming() {
        let row = BrowseRow(SearchResult(id: AddonRef(source: .github, identifier: "o/R"), name: "R", owner: "o",
                                         support: .unsupported, availableFlavors: [.mainline], origin: [.catalogue]), flavor: .forever)
        #expect(row.games.isChecked && row.isDimmed)
        let own = BrowseRow(SearchResult(id: AddonRef(source: .github, identifier: "o/F"), name: "F", owner: "o",
                                         support: .supported(version: "1"), availableFlavors: [.forever], origin: [.catalogue]), flavor: .forever)
        #expect(!own.isDimmed)
    }

    @Test func visibleTargetsPreferUncheckedAndCapAtTwenty() {
        let rows = (0..<30).map { i in
            BrowseRow(SearchResult(id: AddonRef(source: .github, identifier: "o/r\(i)"), name: "r\(i)", owner: "o",
                                   availableFlavors: i < 5 ? [.forever] : nil, origin: [.catalogue]), flavor: .forever)
        }
        let visible = Set(rows.prefix(25).map(\.id))
        let targets = BrowseModel.visibleCheckTargets(rows: rows, visible: visible)
        #expect(targets.count == 20)
        #expect(targets.first?.identifier == "o/r5", "unchecked rows go first")
        #expect(!targets.contains { $0.identifier == "o/r29" }, "only rows on screen")
    }

    /// The app's copy of the cap is a stopgap until the core orders and caps visible checks.
    @Test func visibleCheckLimitMatchesTheCore() {
        #expect(BrowseModel.visibleCheckLimit == AddonManager.visibleCheckLimit)
    }
}
