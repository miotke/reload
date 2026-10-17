import AddonKit
import Foundation
import Testing

/// Main-actor time budgets for the Browse table at its full 500 rows per list
/// (docs/performance/measurements.md#app). Budgets are generous; they catch per-row
/// formatting or O(n²) work, not a slow machine.
/// A timing budget scaled by `RELOAD_PERF_SLACK` (1 when unset). CI sets 3: shared runners
/// are slower, and the budgets are there to catch O(n²) work, not a slow machine.
func budget(_ duration: Duration) -> Duration {
    duration * (Double(ProcessInfo.processInfo.environment["RELOAD_PERF_SLACK"] ?? "") ?? 1)
}

@Suite(.serialized) struct BrowsePerformanceTests {
    static let count = 500

    static func results(_ prefix: String, now: Date = .now) -> [SearchResult] {
        (0..<count).map { i in
            var result = SearchResult(
                id: AddonRef(source: .github, identifier: "owner\(i % 90)/\(prefix)\(i)"), name: "\(prefix) \(i)",
                summary: "Description of add-on \(i)", owner: "owner\(i % 90)", stars: i % 5 == 0 ? i * 3 : nil,
                lastUpdated: now.addingTimeInterval(-Double(i) * 7_200), origin: [.catalogue])
            result.support = i % 2 == 0 ? .supported(version: "v\(i)") : .unknown
            result.availableFlavors = i % 3 == 0 ? nil : [.forever, .mainline, .vanilla]
            return result
        }
    }

    static func makeModel() async -> BrowseModel {
        var manager = FixtureManager()
        manager.content = BrowseContent(popular: results("Popular"), recent: results("Recent"), categories: [])
        let installed = InstalledModel(installation: Fixtures.installation, manager: manager, reportError: { _ in })
        let browse = BrowseModel(installation: Fixtures.installation, manager: manager, installed: installed)
        browse.options = BrowseOptions(showsOtherGames: true)
        return browse
    }

    static func median(runs: Int = 7, _ body: () async -> Void) async -> Duration {
        await body()
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<runs { times.append(await clock.measure(body)) }
        return times.sorted()[runs / 2]
    }

    static func ms(_ duration: Duration) -> String {
        String(format: "%.2f ms", Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
    }

    @Test func rebuildingFiveHundredRowsFitsInAFrame() async {
        let browse = await Self.makeModel()
        await browse.loadBrowse()
        #expect(browse.rows.count == Self.count)
        let rebuild = await Self.median { browse.rebuildRows() }
        browse.options.sort = ColumnSort(BrowseColumn.name)
        let byName = await Self.median { browse.rebuildRows() }
        browse.options.sort = ColumnSort(BrowseColumn.games)
        let byGames = await Self.median { browse.rebuildRows() }
        print("Browse rebuild (500 rows): unsorted \(Self.ms(rebuild)), by name \(Self.ms(byName)), by games \(Self.ms(byGames))")
        #expect(rebuild < budget(.milliseconds(16)), "rebuild took \(rebuild)")
        #expect(byName < budget(.milliseconds(30)), "sorting by name took \(byName)")
        #expect(byGames < budget(.milliseconds(16)), "sorting by games took \(byGames)")
    }

    /// A live patch from a refresh (every row's verdict changed): one rebuild, within a frame.
    @Test func patchingEveryRowFitsInAFrame() async {
        let browse = await Self.makeModel()
        await browse.loadBrowse()
        var flip = false
        let patch = await Self.median {
            flip.toggle()
            let answers = Dictionary(uniqueKeysWithValues: (browse.content?.popular ?? []).map {
                ($0.id, StoredAvailability(support: flip ? .unsupported : .supported(version: "v2"), availableFlavors: [.forever]))
            })
            browse.applyStored(answers)
        }
        print("Browse patch (500 rows): \(Self.ms(patch))")
        #expect(patch < budget(.milliseconds(16)), "patch took \(patch)")
    }
}
