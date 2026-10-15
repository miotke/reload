import Foundation
import Testing
@testable import AddonKit

/// Time budgets for search, Browse and the WoWInterface listing at realistic sizes
/// (docs/performance/measurements.md#sources-at-realistic-sizes): ~2,400 GitHub catalogue rows
/// and an ~8,200-file, ~5.6 MB WoWInterface listing. Budgets are several times the measured
/// numbers, so they catch O(n²) work or per-row overhead, not a slow machine.
@Suite(.serialized) struct SourcesPerformanceTests {
    static let githubCount = 2_400
    static let hostedCount = 8_200
    static let listing = "https://api.mmoui.com/v3/game/WOW/filelist.json"

    /// A listing shaped like `filelist.json`: every field the real one has, ~680 bytes a file.
    static let listingData: Data = {
        let words = ["Quest", "Bag", "Raid", "Frames", "Tracker", "Map", "Loot", "Auction", "Chat", "Tooltip", "Bars", "Mods"]
        let files = (0..<hostedCount).map { i in
            let name = "\(words[i % words.count]) \(words[(i / 12) % words.count]) \(i)"
            let compatibility = i % 3 == 0
                ? #"[{"version":"11.2.5","name":"The War Within"},{"version":"1.15.7","name":"Classic"}]"#
                : #"[{"version":"11.2.5","name":"The War Within"}]"#
            let images = i % 2 == 0
                ? #"["https://cdn-wow.mmoui.com/preview/pvw\#(i)a.jpg","https://cdn-wow.mmoui.com/preview/pvw\#(i)b.jpg"]"#
                : "null"
            return #"{"UID":"\#(10_000 + i)","UICATID":"19","UIVersion":"1.\#(i % 40).\#(i % 7)","UIDate":\#(1_790_000_000_000 - Int64(i) * 3_600_000),"UIName":"\#(name)","UIAuthorName":"Author\#(i % 900)","UIFileInfoURL":"https://www.wowinterface.com/downloads/info\#(10_000 + i)-\#(name.replacingOccurrences(of: " ", with: "")).html","UIDownloadTotal":"\#(i * 37)","UIDownloadMonthly":"\#(i % 300)","UIFavoriteTotal":"\#(i % 90)","UICompatibility":\#(compatibility),"UIDir":["\#(name.replacingOccurrences(of: " ", with: ""))","\#(name.replacingOccurrences(of: " ", with: ""))_Options"],"UIIMG_Thumbs":\#(images.replacingOccurrences(of: "preview/", with: "preview/tiny/")),"UIIMGs":\#(images),"UISiblings":null,"UIDonationLink":"https://www.paypal.com/donate?id=\#(i)","UIMD5":"0123456789abcdef0123456789abcdef"}"#
        }
        return Data(("[" + files.joined(separator: ",\n") + "]").utf8)
    }()

    /// A manager whose database holds 2,400 GitHub catalogue rows, half with a Forever
    /// verdict and stored flavors, a sixth with stars, and the WoWInterface listing imported.
    static func seeded() async throws -> ManagerHarness {
        let h = try await ManagerHarness()
        let database = h.manager.database
        let now = Date()
        let words = ["Bag", "Quest", "Boss", "Weak", "Auras", "Helper", "Unit", "Frames", "Damage", "Meter"]
        let entries = (0..<githubCount).map { i in
            CatalogueEntry(
                id: "\(i)", name: "\(words[i % 10])\(words[(i / 10) % 10])\(i)", fullName: "owner\(i % 700)/Repo\(i)",
                url: URL(string: "https://github.com/owner\(i % 700)/Repo\(i)")!,
                description: "Description of add-on number \(i) for raids and quests",
                lastUpdated: now.addingTimeInterval(-Double(i) * 5_000), flavors: ["mainline"],
                hasReleaseJSON: i % 3 != 0)
        }
        _ = try await database.importCatalogue(entries, etag: "\"seed\"", at: now)
        try await database.transaction { db in
            let support = try db.prepare("INSERT INTO support(full_name, flavor, status, version, tag, checked_at) VALUES (?, ?, ?, ?, ?, ?)")
            let meta = try db.prepare("""
                INSERT INTO repo_meta(full_name, latest_tag, tag_checked_at, stars, available_flavors, flavors_tag, flavors_source)
                VALUES (?, ?, ?, ?, ?, ?, 'release_json')
                """)
            for i in 0..<(githubCount / 2) {
                let name = SQLValue.text(entries[i].fullName), tag = SQLValue.text("v\(i)")
                try db.step(support, [name, .text("forever"), .text(i % 2 == 0 ? "supported" : "unsupported"),
                                      i % 2 == 0 ? tag : .null, tag, .real(now.timeIntervalSince1970)])
                try db.step(meta, [name, tag, .real(now.timeIntervalSince1970), i % 6 == 0 ? .integer(Int64(i)) : .null,
                                   .text(i % 2 == 0 ? "forever,mainline" : "mainline"), tag])
            }
        }
        h.http.stub(listing, body: listingData)
        _ = try await h.manager.hosted.refresh(.wowinterface, force: true)
        return h
    }

    @Test func listingParseAndImportStayFast() async throws {
        let data = Self.listingData
        #expect(data.count > 5_000_000)
        let parse = await DatabasePerformanceTests.median(runs: 3) { _ = try? WoWInterface().entries(fromListing: data) }
        let entries = try WoWInterface().entries(fromListing: data)
        #expect(entries.count == Self.hostedCount)

        // A first import into an empty table, each run in a fresh database.
        var firsts: [Duration] = []
        for _ in 0..<3 {
            let database = try MetadataDatabase.inMemory()
            firsts.append(try await ContinuousClock().measure {
                try await database.importHostedListing(entries, source: .wowinterface, etag: nil, at: Date())
            })
        }
        let first = firsts.sorted()[1]
        let database = try MetadataDatabase.inMemory()
        try await database.importHostedListing(entries, source: .wowinterface, etag: nil, at: Date())
        let unchanged = await DatabasePerformanceTests.median(runs: 3) {
            try? await database.importHostedListing(entries, source: .wowinterface, etag: nil, at: Date())
        }
        let load = await DatabasePerformanceTests.median { _ = try? await database.catalogueEntries() }
        let loaded = try await database.catalogueEntries()
        #expect(loaded.count == Self.hostedCount)
        #expect(loaded.first { $0.id == "10000" }?.screenshots?.count == 2)
        let index = await DatabasePerformanceTests.median(runs: 3) { _ = SearchIndex(entries: loaded) }

        print("""
            listing \(data.count / 1_000) KB: parse \(DatabasePerformanceTests.ms(parse)), \
            first import \(DatabasePerformanceTests.ms(first)), unchanged import \(DatabasePerformanceTests.ms(unchanged)), \
            catalogueEntries \(DatabasePerformanceTests.ms(load)), index build \(DatabasePerformanceTests.ms(index))
            """)
        #expect(parse < budget(.milliseconds(400)), "parse took \(parse)")
        #expect(first < budget(.milliseconds(300)), "first import took \(first)")
        #expect(unchanged < budget(.milliseconds(200)), "unchanged import took \(unchanged)")
        #expect(load < budget(.milliseconds(100)), "catalogueEntries took \(load)")
        #expect(index < budget(.milliseconds(400)), "index build took \(index)")
    }

    @Test func searchAndBrowseStayFastWithEverySource() async throws {
        let h = try await Self.seeded()
        let manager = h.manager
        #expect(try await manager.database.catalogueEntries().count == Self.githubCount + Self.hostedCount)

        // The daily re-download: parse plus an import that changes nothing, in the WAL file.
        let hosted = await manager.hosted
        let redownload = await DatabasePerformanceTests.median(runs: 3) { _ = try? await hosted.refresh(.wowinterface, force: true) }
        let enabled = await DatabasePerformanceTests.median(runs: 21) { _ = await manager.database.enabledSources() }
        let browse = await DatabasePerformanceTests.median { _ = await manager.browse(in: h.installation) }
        let content = await manager.browse(in: h.installation)
        #expect(content.recent.count == SearchCoordinator.browseLimit)

        var times: [String: Duration] = [:]
        for text in ["b", "bag", "quest frames", "raids"] {
            var count = 0
            times[text] = await DatabasePerformanceTests.median {
                for await results in manager.search(SearchQuery(text: text, flavor: .forever, hideIncompatible: false),
                                                    in: h.installation, installed: []) {
                    count = results.count
                }
            }
            #expect(count > 0, "\(text)")
            #expect(count <= SearchCoordinator.catalogueLimit + 50, "\(text): \(count) results")
        }
        // Hosted rows are searched too (their author is indexed; GitHub rows have none).
        var hostedFound = false
        for await results in manager.search(SearchQuery(text: "Author12", flavor: .forever, hideIncompatible: false), in: h.installation, installed: []) {
            hostedFound = results.contains { $0.id.source == .wowinterface }
        }
        #expect(hostedFound)
        let slowest = times.values.max()!
        print("""
            listing re-download \(DatabasePerformanceTests.ms(redownload)), \
            enabledSources \(DatabasePerformanceTests.ms(enabled)), browse \(DatabasePerformanceTests.ms(browse)), \
            search \(times.sorted { $0.key < $1.key }.map { "\($0.key): \(DatabasePerformanceTests.ms($0.value))" }.joined(separator: ", "))
            """)
        #expect(redownload < budget(.milliseconds(500)), "re-download took \(redownload)")
        #expect(enabled < budget(.milliseconds(2)), "enabledSources took \(enabled)")
        #expect(browse < budget(.milliseconds(150)), "browse took \(browse)")
        #expect(slowest < budget(.milliseconds(100)), "search took \(slowest)")
    }

    /// Turning a source off or on rebuilds the index once, then reuses it.
    @Test func togglingASourceRebuildsTheIndexOnce() async throws {
        let h = try await Self.seeded()
        let catalogue = await h.manager.catalogue
        _ = try await catalogue.localSearchIndex()
        let cached = await DatabasePerformanceTests.median { _ = try? await catalogue.localSearchIndex() }
        try await h.manager.setSource(.wowinterface, enabled: false)
        let rebuilt = try await ContinuousClock().measure { _ = try await catalogue.localSearchIndex() }
        #expect(try await catalogue.localSearchIndex().count == Self.githubCount)
        try await h.manager.setSource(.wowinterface, enabled: true)
        let back = try await ContinuousClock().measure { _ = try await catalogue.localSearchIndex() }
        print("""
            index cached \(DatabasePerformanceTests.ms(cached)), GitHub only \(DatabasePerformanceTests.ms(rebuilt)), \
            every source \(DatabasePerformanceTests.ms(back))
            """)
        #expect(cached < budget(.milliseconds(2)), "cached index took \(cached)")
        #expect(back < budget(.milliseconds(600)), "rebuild took \(back)")
    }
}
