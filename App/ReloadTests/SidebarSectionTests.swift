import AddonKit
import Foundation
import Testing

/// The sidebar's section filters, badge counts, stored selection and search scope.
@MainActor @Suite struct SidebarSectionTests {
    static let rows: [InstalledRow] = Fixtures.addons.map { status in
        let update: UpdateState? = if case .managed(let addon, _) = status { Fixtures.updates[addon.id] } else { nil }
        return InstalledRow(status: status, update: update, flavor: .forever)
    }

    @Test func sectionsFilterTheInstalledRows() {
        func names(_ section: LibrarySection) -> [String] { Self.rows.filter(section.includes).map(\.name) }
        #expect(names(.installed) == ["BetterBags", "BugSack", "Deadly Boss Mods", "Details!", "LittleWigs"])
        // Details! has a Forever build waiting to replace its Retail build; DBM is pinned, so no offer.
        #expect(names(.updates) == ["BugSack", "Details!"])
        #expect(names(.unmanaged) == ["Questie", "Old Minimap"])
        #expect(names(.pinned) == ["Deadly Boss Mods"])
    }

    @Test func countsMatchTheFiltersAndUpdateAll() {
        let counts = LibraryCounts(rows: Self.rows)
        #expect(counts == {
            var expected = LibraryCounts()
            expected.installed = 5
            expected.updates = 2
            expected.unmanaged = 2
            expected.pinned = 1
            return expected
        }())
        for section in LibrarySection.allCases {
            #expect(counts[section] == Self.rows.filter(section.includes).count)
        }
        #expect(LibraryCounts(rows: []) == LibraryCounts())
    }

    @Test func modelFiltersBySectionAndQueryButCountsIgnoreTheQuery() async {
        let state = InstallationModel(installation: Fixtures.installation, manager: FixtureManager(), reportError: { _ in })
        await state.installed.reload()
        state.queue.apply(Fixtures.updates)
        #expect(state.installed.rows.map(\.name) == ["BetterBags", "BugSack", "Deadly Boss Mods", "Details!", "LittleWigs"])
        #expect(state.installed.counts.updates == state.installed.updateCount)

        state.installed.options.section = .updates
        state.installed.options.query = "bug"
        #expect(state.installed.rows.map(\.name) == ["BugSack"])
        #expect(state.installed.counts.updates == 2)

        state.installed.options.section = .unmanaged
        state.installed.options.query = "questie"
        #expect(state.installed.rows.map(\.name) == ["Questie"])
    }

    @Test func selectionRoundTripsThroughItsStoredValue() {
        let items: [SidebarItem] = LibrarySection.allCases.map { .library($0) } + [.browse, .category("boss-mods")]
        for item in items { #expect(SidebarItem(rawValue: item.rawValue) == item) }
        #expect(SidebarItem(rawValue: "nonsense") == nil)
    }

    @Test func searchScopeFollowsTheSection() {
        let categories = SearchAliases.categories
        #expect(SidebarItem.library(.pinned).browseQuery(typed: "dbm", categories: categories) == nil)
        #expect(SidebarItem.browse.browseQuery(typed: " weak ", categories: categories) == "weak")
        #expect(SidebarItem.category("bags").browseQuery(typed: "", categories: categories) == "bag")
        #expect(SidebarItem.category("bags").browseQuery(typed: "sort", categories: categories) == "bag sort")
        // A category that's no longer offered reads as Browse.
        #expect(SidebarItem.category("gone").browseQuery(typed: "x", categories: categories) == "x")

        #expect(SidebarItem.library(.updates).searchPrompt(categories: categories) == "Filter updates")
        #expect(SidebarItem.browse.searchPrompt(categories: categories) == "Search add-ons")
        #expect(SidebarItem.category("maps").searchPrompt(categories: categories) == "Search Maps")
    }

    @Test func appModelClearsTheSearchOnASectionChangeExceptSearchAll() {
        let model = AppModel(manager: FixtureManager())
        model.searchText = "bag"
        model.section = .library(.pinned)
        #expect(model.searchText.isEmpty)
        model.searchText = "bag"
        model.searchAllAddons()
        #expect(model.section == .browse)
        #expect(model.searchText == "bag")
    }
}
