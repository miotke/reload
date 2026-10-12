import Foundation
import Testing
@testable import AddonKit

/// Time budgets for the metadata database's hot paths on a realistically sized file in a temp
/// folder (docs/performance/measurements.md#sqlite). Budgets are ~10× the measured numbers, so
/// they catch an N+1 or a missing index, not a slow CI machine.
@Suite(.serialized) struct DatabasePerformanceTests {
    static let catalogueCount = 5_000
    static let supportCount = 3_000
    static let browseRefs = 500

    /// A manager over a temp data folder holding a catalogue of 5k repos, verdicts for 3k of
    /// them (Forever) plus 1k Retail, repo metadata with flavors and stars, a stored
    /// release.json per checked repo, 200 live-search answers and 100 release folder lists.
    static func seeded() async throws -> ManagerHarness {
        let h = try await ManagerHarness()
        let database = h.manager.database
        let now = Date()
        let entries = (0..<catalogueCount).map { i in
            CatalogueEntry(
                id: "\(i)", name: "Addon\(i)", fullName: "owner\(i % 700)/Addon\(i)",
                url: URL(string: "https://github.com/owner\(i % 700)/Addon\(i)")!,
                description: "Description of add-on number \(i) for raids and quests",
                lastUpdated: now.addingTimeInterval(-Double(i) * 3_600), flavors: ["mainline"],
                hasReleaseJSON: i % 3 != 0)
        }
        _ = try await database.importCatalogue(entries, etag: "\"seed\"", at: now)
        let json = Self.releaseJSON
        try await database.transaction { db in
            let support = try db.prepare("""
                INSERT INTO support(full_name, flavor, status, version, tag, checked_at) VALUES (?, ?, ?, ?, ?, ?)
                """)
            let meta = try db.prepare("""
                INSERT INTO repo_meta(full_name, latest_tag, tag_checked_at, stars, available_flavors, flavors_tag, flavors_source)
                VALUES (?, ?, ?, ?, ?, ?, 'release_json')
                """)
            let release = try db.prepare("INSERT INTO release_json(full_name, tag, json, fetched_at) VALUES (?, ?, ?, ?)")
            for i in 0..<supportCount {
                let name = SQLValue.text(entries[i].fullName)
                let tag = SQLValue.text("v\(i)")
                let status = i % 2 == 0 ? "supported" : "unsupported"
                try db.step(support, [name, .text("forever"), .text(status), i % 2 == 0 ? tag : .null, tag,
                                      .real(now.addingTimeInterval(-Double(i) * 60).timeIntervalSince1970)])
                if i < 1_000 {
                    try db.step(support, [name, .text("mainline"), .text("supported"), tag, tag, .real(now.timeIntervalSince1970)])
                }
                try db.step(meta, [name, tag, .real(now.timeIntervalSince1970), i % 6 == 0 ? .integer(Int64(i)) : .null,
                                   .text(i % 2 == 0 ? "forever,mainline,vanilla" : "mainline"), tag])
                try db.step(release, [name, tag, .text(json), .real(now.timeIntervalSince1970)])
            }
            for i in 0..<200 {
                try db.execute("INSERT INTO search_cache(query, full_names, fetched_at) VALUES (?, ?, ?)",
                               "query \(i)", (0..<5).map { entries[i * 5 + $0].fullName }.joined(separator: "\n"), now)
            }
            for i in 0..<100 {
                try db.execute("INSERT INTO release_folders(full_name, tag, folders_json, recorded_at) VALUES (?, ?, ?, ?)",
                               entries[i].fullName, "v\(i)", "[\"Addon\(i)\",\"Addon\(i)_Options\"]", now)
            }
        }
        return h
    }

    /// A typical packager release.json: five builds.
    static let releaseJSON = """
        {"releases":[\((["mainline", "classic", "bcc", "wrath", "cata"]).map { flavor in
            #"{"name":"Addon","version":"v1","filename":"Addon-v1-\#(flavor).zip","nolib":false,"metadata":[{"flavor":"\#(flavor)","interface":110000}]}"#
        }.joined(separator: ","))]}
        """

    /// The median of `runs` timings, after one warm-up.
    static func median(runs: Int = 5, _ body: () async -> Void) async -> Duration {
        await body()
        var times: [Duration] = []
        let clock = ContinuousClock()
        for _ in 0..<runs { times.append(await clock.measure(body)) }
        return times.sorted()[runs / 2]
    }

    static func ms(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.2f ms", value)
    }

    @Test func browseAndSearchStayFastWithAFullDatabase() async throws {
        let h = try await Self.seeded()
        let manager = h.manager
        let browse = await Self.median { _ = await manager.browse(in: h.installation) }
        let content = await manager.browse(in: h.installation)
        #expect(content.popular.count == Self.browseRefs)
        #expect(content.recent.count == Self.browseRefs)
        let search = await Self.median {
            for await _ in manager.search(SearchQuery(text: "addon1", flavor: .forever), in: h.installation, installed: []) {}
        }
        print("browse: \(Self.ms(browse)), search: \(Self.ms(search))")
        #expect(browse < .milliseconds(150), "browse took \(browse)")
        #expect(search < .milliseconds(150), "search took \(search)")
    }

    /// A Browse list's patch after a refresh touched every row: one read, not two per row.
    @Test func storedAvailabilityForAWholeBrowseListIsOneRead() async throws {
        let h = try await Self.seeded()
        let manager = h.manager
        let refs = (0..<Self.browseRefs).map { AddonRef(source: .github, identifier: "owner\($0 % 700)/Addon\($0)") }
        let time = await Self.median { _ = await manager.storedAvailability(for: refs, in: h.installation) }
        let stored = await manager.storedAvailability(for: refs, in: h.installation)
        #expect(stored.count == Self.browseRefs)
        #expect(stored[refs[0]]?.support == .supported(version: "v0"))
        #expect(stored[refs[0]]?.availableFlavors == [.forever, .mainline, .vanilla])
        #expect(stored[refs[1]]?.support == .unsupported)
        // The same answers as the per-repo lookups, whatever the ref's case; nothing for a
        // repo that was never checked or only ever failed.
        let cache = SupportCache(database: manager.database)
        for ref in refs.prefix(50) {
            #expect(stored[ref]?.support == (await cache.status(for: ref, flavor: .forever)))
            #expect(stored[ref]?.availableFlavors == (await cache.availableFlavors(for: ref)))
        }
        let failed = AddonRef(source: .github, identifier: "x/failed")
        await cache.set(.unknown, for: failed, flavor: .forever)
        let upper = AddonRef(source: .github, identifier: refs[0].identifier.uppercased())
        let never = AddonRef(source: .github, identifier: "x/never")
        let mixed = await manager.storedAvailability(for: [upper, failed, never], in: h.installation)
        #expect(mixed[upper]?.support == .supported(version: "v0"))
        #expect(mixed[failed]?.support == nil && mixed[failed]?.availableFlavors == nil)
        #expect(mixed[never]?.support == nil && mixed[never]?.availableFlavors == nil)
        print("storedAvailability(500): \(Self.ms(time))")
        #expect(time < .milliseconds(30), "storedAvailability took \(time)")
    }

    @Test func refreshTargetsAndOtherReadsStayFast() async throws {
        let h = try await Self.seeded()
        let manager = h.manager
        let seed = await Self.median {
            _ = await manager.supportTargets(installation: h.installation, installed: [], diff: CatalogueDiff(), seed: true)
        }
        let later = await Self.median {
            _ = await manager.supportTargets(installation: h.installation, installed: [], diff: CatalogueDiff(), seed: false)
        }
        let folders = await Self.median { _ = await manager.database.releaseFolders() }
        print("supportTargets seed: \(Self.ms(seed)), later: \(Self.ms(later)), releaseFolders: \(Self.ms(folders))")
        #expect(seed < .milliseconds(100), "seed targets took \(seed)")
        #expect(later < .milliseconds(100), "later targets took \(later)")
        #expect(folders < .milliseconds(20), "release folders took \(folders)")
    }

    /// Every hot query is answered from an index or a primary key, never by scanning a table
    /// that grows with the catalogue, except where the scan is the point (whole-table reads).
    @Test func hotQueriesUseAnIndex() async throws {
        let h = try await Self.seeded()
        let database = h.manager.database
        let lookups: [(String, [any SQLBindable])] = [
            ("SELECT status, version, tag, checked_at, error_at, retry_after FROM support WHERE full_name = ? AND flavor = ?", ["a/b", "forever"]),
            ("SELECT full_name, status, version, tag, checked_at FROM support WHERE flavor = ? AND status IS NOT NULL", ["forever"]),
            ("SELECT available_flavors, flavors_tag, flavors_source FROM repo_meta WHERE full_name = ?", ["a/b"]),
            ("SELECT json FROM release_json WHERE full_name = ? AND tag = ?", ["a/b", "v1"]),
            ("SELECT full_names, fetched_at FROM search_cache WHERE query = ?", ["x"]),
            ("SELECT \(MetadataDatabase.catalogueColumns) FROM catalogue WHERE full_name = ?", ["a/b"]),
            ("SELECT full_name FROM support WHERE flavor = ? AND checked_at < ? ORDER BY checked_at LIMIT ?", ["forever", 0.0, 50]),
        ]
        // The batched availability read walks its own list and probes both tables by key.
        let batch = try await database.query("""
            EXPLAIN QUERY PLAN SELECT r.value, s.status, m.available_flavors FROM json_each(?) r
            LEFT JOIN support s ON s.full_name = r.value AND s.flavor = ? AND s.status IS NOT NULL
            LEFT JOIN repo_meta m ON m.full_name = r.value
            """, "[]", "forever").compactMap { $0.string(3) }
        #expect(batch.filter { $0.hasPrefix("SCAN") }.allSatisfy { $0.hasPrefix("SCAN r") }, "\(batch)")
        for (sql, arguments) in lookups {
            let plan = try await database.query("EXPLAIN QUERY PLAN " + sql, arguments).compactMap { $0.string(3) }
            #expect(plan.allSatisfy { !$0.hasPrefix("SCAN") }, "\(sql): \(plan)")
        }
    }
}
