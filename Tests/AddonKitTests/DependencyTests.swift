import Foundation
import SQLite3
import Testing
@testable import AddonKit

/// Missing required add-ons, their candidates, and dependents (docs/features/dependencies.md).
@Suite struct DependencyTests {
    static let littleWigs = AddonRef(source: .github, identifier: "BigWigsMods/LittleWigs")
    static let bigWigs = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs")

    /// Writes `AddOns/<folder>/<file>` for each TOC.
    func addFolder(_ h: ManagerHarness, _ folder: String, tocs: [String: String]) throws {
        let url = h.installation.addonsDirectory.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (file, text) in tocs { try Data(text.utf8).write(to: url.appending(path: file)) }
        try Data("-- code".utf8).write(to: url.appending(path: "Core.lua"))
    }

    /// A managed add-on whose folders each get a Forever TOC requiring `requires`.
    func manage(_ h: ManagerHarness, _ ref: AddonRef, name: String, folders: [String], requires: [String] = []) async throws {
        for folder in folders {
            let deps = requires.isEmpty ? "" : "## Dependencies: \(requires.joined(separator: ", "))\n"
            try addFolder(h, folder, tocs: ["\(folder).toc": "## Interface: 16001\n## Title: \(folder)\n" + deps])
        }
        try await h.manager.store.upsert(InstalledAddon(
            id: ref, name: name, folders: folders, version: "v1", releaseID: 1, assetName: "\(name).zip",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000), installedAt: Date(timeIntervalSince1970: 1_700_000_100),
            channel: .stable, pinned: false
        ), in: h.installation)
    }

    func gitHubEntry(_ repo: String, name: String, updated: TimeInterval = 1_790_000_000) -> CatalogueEntry {
        CatalogueEntry(id: repo, name: name, fullName: repo, url: URL(string: "https://github.com/\(repo)")!,
                       lastUpdated: Date(timeIntervalSince1970: updated))
    }

    func hostedEntry(_ ref: AddonRef, name: String, folders: [String], updated: TimeInterval = 1_790_000_000) -> CatalogueEntry {
        CatalogueEntry(id: ref.identifier, name: name, fullName: ref.key, url: ref.webURL!,
                       lastUpdated: Date(timeIntervalSince1970: updated), source: ref.source, folders: folders)
    }

    /// LittleWigs installed, requiring BigWigs, which isn't.
    func littleWigsHarness() async throws -> ManagerHarness {
        let h = try await ManagerHarness()
        try await manage(h, Self.littleWigs, name: "LittleWigs", folders: ["LittleWigs"], requires: ["BigWigs"])
        return h
    }

    // MARK: - Detection

    @Test func readsTheTocTheGameLoads() async throws {
        let h = try await ManagerHarness()
        try addFolder(h, "LittleWigs", tocs: [
            // Retail's TOC asks for something Forever's doesn't; Forever reads `_Camelot`.
            "LittleWigs.toc": "## Interface: 110200\n## Dependencies: RetailOnly\n",
            "LittleWigs_Camelot.toc": """
                ## Interface: 16001
                ## Dependencies: BigWigs, Blizzard_EncounterJournal
                ## OptionalDeps: Details, LibStub
                """,
        ])
        try await h.manager.store.upsert(InstalledAddon(
            id: Self.littleWigs, name: "LittleWigs", folders: ["LittleWigs"], version: "v1", releaseID: 1, assetName: "l.zip",
            publishedAt: .now, installedAt: .now, channel: .stable, pinned: false), in: h.installation)

        let missing = await h.manager.missingDependencies(in: h.installation)
        #expect(missing.map(\.folder) == ["BigWigs"])
        #expect(missing.first?.requiredBy == [Self.littleWigs])
        #expect(missing.first?.suggested == nil)
    }

    @Test func requiredDepsAndDepSpellingsCount() async throws {
        let h = try await ManagerHarness()
        try addFolder(h, "A", tocs: ["A.toc": "## Interface: 16001\n## RequiredDeps: LibA\n"])
        try addFolder(h, "B", tocs: ["B.toc": "## Interface: 16001\n## Dep: LibB\n"])
        try await h.manager.store.upsert(InstalledAddon(
            id: AddonRef(source: .github, identifier: "o/AB"), name: "AB", folders: ["A", "B"], version: "v1", releaseID: 1,
            assetName: "ab.zip", publishedAt: .now, installedAt: .now, channel: .stable, pinned: false), in: h.installation)
        #expect(await h.manager.missingDependencies(in: h.installation).map(\.folder) == ["LibA", "LibB"])
    }

    @Test func anyFolderOnDiskSatisfiesIt() async throws {
        let h = try await littleWigsHarness()
        // Unmanaged, and spelled differently.
        try addFolder(h, "bigwigs", tocs: ["bigwigs.toc": "## Interface: 16001\n"])
        #expect(await h.manager.missingDependencies(in: h.installation).isEmpty)
    }

    @Test func groupsByFolderAndIgnoresOwnFolders() async throws {
        let h = try await littleWigsHarness()
        try await manage(h, AddonRef(source: .github, identifier: "o/Capping"), name: "Capping", folders: ["Capping"], requires: ["bigwigs"])
        // Requires its own (missing) folder: that's a missing folder, not a dependency.
        try await manage(h, AddonRef(source: .github, identifier: "o/Pack"), name: "Pack", folders: ["Pack"], requires: ["Pack_Data"])
        try await h.manager.store.modify(h.installation) { addons in
            if let i = addons.firstIndex(where: { $0.name == "Pack" }) { addons[i].folders.append("Pack_Data") }
        }

        // Named as the first add-on (by name) spells it.
        let missing = await h.manager.missingDependencies(in: h.installation)
        #expect(missing.map(\.folder) == ["bigwigs"])
        #expect(missing.first?.requiredBy == [AddonRef(source: .github, identifier: "o/Capping"), Self.littleWigs])

        let one = await h.manager.missingDependencies(of: AddonRef(source: .github, identifier: "o/Capping"), in: h.installation)
        #expect(one.map(\.folder) == ["bigwigs"])
        #expect(one.first?.requiredBy == [AddonRef(source: .github, identifier: "o/Capping")])
        #expect(await h.manager.missingDependencies(of: Self.bigWigs, in: h.installation).isEmpty)
    }

    @Test func folderTheGameDoesNotLoadRequiresNothing() async throws {
        let h = try await ManagerHarness()
        try addFolder(h, "RetailThing", tocs: ["RetailThing_Mists.toc": "## Interface: 50500\n## Dependencies: BigWigs\n"])
        try await h.manager.store.upsert(InstalledAddon(
            id: AddonRef(source: .github, identifier: "o/RetailThing"), name: "RetailThing", folders: ["RetailThing"],
            version: "v1", releaseID: 1, assetName: "r.zip", publishedAt: .now, installedAt: .now, channel: .stable, pinned: false),
            in: h.installation)
        #expect(await h.manager.missingDependencies(in: h.installation).isEmpty)
    }

    // MARK: - Candidates

    @Test func hostedListingFolderIsSuggested() async throws {
        let h = try await littleWigsHarness()
        let wowi = AddonRef(source: .wowinterface, identifier: "5086")
        try await h.manager.database.importHostedListing([
            hostedEntry(wowi, name: "BigWigs Bossmods", folders: ["BigWigs", "BigWigs_Core"]),
            hostedEntry(AddonRef(source: .wowinterface, identifier: "7"), name: "Other", folders: ["Other"]),
        ], source: .wowinterface, etag: nil, at: .now)

        let dependency = try #require(await h.manager.missingDependencies(in: h.installation).first)
        #expect(dependency.candidates.map(\.ref) == [wowi])
        #expect(dependency.candidates.first?.reason == "WoWInterface lists the BigWigs folder")
        #expect(dependency.suggested?.ref == wowi)
    }

    @Test func severalListingsSuggestNothing() async throws {
        let h = try await littleWigsHarness()
        let a = AddonRef(source: .wowinterface, identifier: "1"), b = AddonRef(source: .wowinterface, identifier: "2")
        try await h.manager.database.importHostedListing([
            hostedEntry(a, name: "Raid Pack", folders: ["BigWigs", "Pack"], updated: 1_790_000_000),
            hostedEntry(b, name: "BigWigs", folders: ["BigWigs"], updated: 1_700_000_000),
        ], source: .wowinterface, etag: nil, at: .now)

        let dependency = try #require(await h.manager.missingDependencies(in: h.installation).first)
        // The one named like the folder ranks first, though it's older.
        #expect(dependency.candidates.map(\.ref) == [b, a])
        #expect(dependency.suggested == nil)
    }

    @Test func downloadedReleaseFoldersRankFirst() async throws {
        let h = try await littleWigsHarness()
        _ = try await h.manager.database.importCatalogue([gitHubEntry("BigWigsMods/BigWigs", name: "BigWigs")], etag: nil, at: .now)
        await h.manager.database.setReleaseFolders(["BigWigs", "BigWigs_Core"], tag: "v400", for: "BigWigsMods/BigWigs", at: .now)
        let wowi = AddonRef(source: .wowinterface, identifier: "5086")
        try await h.manager.database.importHostedListing(
            [hostedEntry(wowi, name: "BigWigs", folders: ["BigWigs"])], source: .wowinterface, etag: nil, at: .now)

        let dependency = try #require(await h.manager.missingDependencies(in: h.installation).first)
        #expect(dependency.candidates.map(\.ref) == [Self.bigWigs, wowi])
        #expect(dependency.candidates.map(\.reason) == ["Its download shipped the BigWigs folder", "WoWInterface lists the BigWigs folder"])
        #expect(dependency.candidates.first?.name == "BigWigs")
        #expect(dependency.suggested?.ref == Self.bigWigs)
    }

    @Test func aSingleCatalogueNameMatchIsSuggested() async throws {
        let h = try await littleWigsHarness()
        _ = try await h.manager.database.importCatalogue([
            gitHubEntry("BigWigsMods/BigWigs", name: "BigWigs"),
            gitHubEntry("BigWigsMods/LittleWigs", name: "LittleWigs"),
        ], etag: nil, at: .now)

        let dependency = try #require(await h.manager.missingDependencies(in: h.installation).first)
        #expect(dependency.candidates.map(\.ref) == [Self.bigWigs])
        #expect(dependency.candidates.first?.reason == "Named BigWigs in the catalogue")
        #expect(dependency.suggested?.ref == Self.bigWigs)
    }

    @Test func severalNameMatchesSuggestNothing() async throws {
        let h = try await littleWigsHarness()
        _ = try await h.manager.database.importCatalogue([
            gitHubEntry("BigWigsMods/BigWigs", name: "BigWigs", updated: 1_790_000_000),
            gitHubEntry("someone/BigWigs", name: "BigWigs", updated: 1_700_000_000),
        ], etag: nil, at: .now)

        let dependency = try #require(await h.manager.missingDependencies(in: h.installation).first)
        #expect(dependency.candidates.map(\.ref) == [Self.bigWigs, AddonRef(source: .github, identifier: "someone/BigWigs")])
        #expect(dependency.suggested == nil)
    }

    @Test func sourcesThatAreOffOfferNothing() async throws {
        let h = try await littleWigsHarness()
        _ = try await h.manager.database.importCatalogue([gitHubEntry("BigWigsMods/BigWigs", name: "BigWigs")], etag: nil, at: .now)
        await h.manager.database.setReleaseFolders(["BigWigs"], tag: "v400", for: "BigWigsMods/BigWigs", at: .now)
        let wowi = AddonRef(source: .wowinterface, identifier: "5086")
        try await h.manager.database.importHostedListing(
            [hostedEntry(wowi, name: "BigWigs", folders: ["BigWigs"])], source: .wowinterface, etag: nil, at: .now)

        try await h.manager.setSource(.github, enabled: false)
        var dependency = try #require(await h.manager.missingDependencies(in: h.installation).first)
        #expect(dependency.candidates.map(\.ref) == [wowi])
        #expect(dependency.suggested?.ref == wowi)

        try await h.manager.setSource(.github, enabled: true)
        try await h.manager.setSource(.wowinterface, enabled: false)
        dependency = try #require(await h.manager.missingDependencies(in: h.installation).first)
        #expect(dependency.candidates.map(\.ref) == [Self.bigWigs])

        try await h.manager.setSource(.github, enabled: false)
        dependency = try #require(await h.manager.missingDependencies(in: h.installation).first)
        #expect(dependency.candidates.isEmpty)
        #expect(dependency.suggested == nil)
    }

    // MARK: - Dependents

    @Test func dependentsAreAddonsThatNeedItsFolders() async throws {
        let h = try await littleWigsHarness()
        try await manage(h, Self.bigWigs, name: "BigWigs", folders: ["BigWigs", "BigWigs_Core"])
        try await manage(h, AddonRef(source: .github, identifier: "o/Plugin"), name: "Plugin", folders: ["Plugin"], requires: ["BigWigs_Core"])
        try await manage(h, AddonRef(source: .github, identifier: "o/Other"), name: "Other", folders: ["Other"], requires: ["LibStub"])

        #expect(await h.manager.missingDependencies(in: h.installation).map(\.folder) == ["LibStub"])
        #expect(await h.manager.dependents(of: Self.bigWigs, in: h.installation).map(\.name) == ["LittleWigs", "Plugin"])
        #expect(await h.manager.dependents(of: Self.littleWigs, in: h.installation).isEmpty)
        #expect(await h.manager.dependents(of: AddonRef(source: .github, identifier: "not/installed"), in: h.installation).isEmpty)
    }

    // MARK: - Listings and storage

    @Test func listingsCarryFolders() throws {
        let wowi = try WoWInterface().entries(fromListing: fixtureData("sources/wowinterface-filelist.json"))
        #expect(wowi.first?.folders == ["QuestLedger"])
        let tukui = try Tukui().entries(fromListing: fixtureData("sources/tukui-addons.json"))
        #expect(tukui.first?.folders == ["ElvUI", "ElvUI_Libraries", "ElvUI_Options"])
    }

    /// Migration 7 on a database a 0.1.5 build left: the column is added and stored listings
    /// are made stale so the next refresh fills it.
    @Test func migrationSevenAddsFoldersAndStalesListings() async throws {
        let url = try makeTempDirectory().appending(path: "metadata.sqlite")
        do {
            var db: OpaquePointer?
            try #require(sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            for step in MetadataDatabase.migrations.prefix(6) { try #require(sqlite3_exec(db, step, nil, nil, nil) == SQLITE_OK) }
            let seed = """
                PRAGMA user_version = 6;
                INSERT INTO catalogue(full_name, id, name, url, source, first_seen_at, seen_at, changed_at)
                    VALUES ('wowinterface:101', '101', 'Quest Ledger', 'https://x.test', 'wowinterface', 1, 1, 1);
                INSERT INTO source_state(source, fetched_at) VALUES ('wowinterface', 1790000000);
                INSERT INTO source_state(source, failed_at) VALUES ('tukui', 1790000000);
                """
            try #require(sqlite3_exec(db, seed, nil, nil, nil) == SQLITE_OK)
        }

        let database = try MetadataDatabase(url: url)
        #expect(try await database.schemaVersion() == 7)
        #expect(try await database.query("SELECT folders_json FROM catalogue").first?[0] == .null)
        #expect(try await database.sourceState(.wowinterface).fetchedAt == Date(timeIntervalSince1970: 0))
        #expect(try await database.sourceState(.tukui).fetchedAt == nil)

        // The next import writes the folders even though nothing else changed.
        let entries = try WoWInterface().entries(fromListing: fixtureData("sources/wowinterface-filelist.json"))
        try await database.importHostedListing(entries, source: .wowinterface, etag: nil, at: .now)
        let found = await database.hostedEntries(shipping: ["questledger"], sources: [.wowinterface])
        #expect(found.map(\.entry.fullName) == ["wowinterface:101"])
        #expect(found.map(\.folder) == ["QuestLedger"])
        #expect(await database.hostedEntries(shipping: ["questledger"], sources: [.tukui]).isEmpty)
    }

    // MARK: - Performance

    /// The Installed list asks for every add-on's missing dependencies; with 100 managed
    /// add-ons of two folders each that's one directory listing and ~200 TOC reads.
    @Test func missingDependenciesForAHundredAddonsIsFast() async throws {
        let h = try await ManagerHarness()
        for i in 0..<100 {
            let folders = ["Addon\(i)", "Addon\(i)_Options"]
            for folder in folders {
                try addFolder(h, folder, tocs: [
                    "\(folder).toc": "## Interface: 110200\n## Dependencies: Addon\(i)\n",
                    "\(folder)_Camelot.toc": "## Interface: 16001\n## Dependencies: Addon\(i), \(i % 10 == 0 ? "Missing\(i)" : "Addon\((i + 1) % 100)")\n## OptionalDeps: LibStub\n",
                ])
            }
            try await h.manager.store.upsert(InstalledAddon(
                id: AddonRef(source: .github, identifier: "owner/Addon\(i)"), name: "Addon\(i)", folders: folders,
                version: "v1", releaseID: Int64(i), assetName: "a.zip", publishedAt: .now, installedAt: .now,
                channel: .stable, pinned: false), in: h.installation)
        }
        _ = try await h.manager.database.importCatalogue(
            (0..<2_000).map { gitHubEntry("owner\($0)/Lib\($0)", name: "Lib\($0)") }, etag: nil, at: .now)

        let manager = h.manager, installation = h.installation
        let missing = await manager.missingDependencies(in: installation)
        #expect(missing.count == 10)
        let time = await DatabasePerformanceTests.median { _ = await manager.missingDependencies(in: installation) }
        print("missingDependencies, 100 add-ons: \(DatabasePerformanceTests.ms(time))")
        #expect(time < budget(.milliseconds(100)), "took \(time)")
    }
}

/// The ranking on its own (docs/features/dependencies.md#candidates).
@Suite struct DependencyMatcherTests {
    let github = AddonRef(source: .github, identifier: "o/BigWigs")

    func named(_ ref: AddonRef, _ name: String, _ source: AdoptionCandidate.Source) -> AdoptionCandidate {
        AdoptionCandidate(ref: ref, name: name, reason: "", source: source)
    }

    @Test func aRepositoryNameMatchAloneIsSuggestedWhenItIsTheFolder() {
        let ranked = DependencyMatcher.rank(folder: "BigWigs", downloaded: [], listed: [], named: [named(github, "Big Wigs", .repoName)])
        #expect(ranked.candidates.first?.reason == "Its repository is named BigWigs")
        #expect(ranked.suggested?.ref == github)
    }

    @Test func eachRefIsListedOnceWithItsStrongestReason() {
        let ranked = DependencyMatcher.rank(
            folder: "BigWigs", downloaded: [.init(ref: github, name: "BigWigs")], listed: [],
            named: [named(github, "BigWigs", .catalogueName)])
        #expect(ranked.candidates.map(\.reason) == ["Its download shipped the BigWigs folder"])
        #expect(ranked.suggested?.ref == github)
    }

    @Test func twoDownloadsSuggestNothing() {
        let other = AddonRef(source: .github, identifier: "o/Pack")
        let ranked = DependencyMatcher.rank(
            folder: "BigWigs", downloaded: [.init(ref: other, name: "Pack"), .init(ref: github, name: "BigWigs")], listed: [], named: [])
        #expect(ranked.candidates.map(\.ref) == [github, other])
        #expect(ranked.suggested == nil)
    }
}
