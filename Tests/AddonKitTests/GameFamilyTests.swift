import Foundation
import SQLite3
import Testing
@testable import AddonKit

/// Game families, every flavor a release ships, and the per-family "hide incompatible" rule
/// (decision 0019).
@Suite struct GameFamilyTests {
    let quickFlask = AddonRef(source: .github, identifier: "test/QuickFlask")
    /// Everything QuickFlask 3.17.1's release.json names.
    let quickFlaskFlavors: Set<Flavor> = [.mists, .mainline, .wrath, .cata, .vanilla, .tbc, .forever]

    @Test func familyMapping() {
        #expect(Flavor.mainline.family == .retail)
        #expect(Flavor.forever.family == .forever)
        for flavor in [Flavor.vanilla, .tbc, .wrath, .titan, .cata, .mists] { #expect(flavor.family == .classic) }
        #expect(GameFamily.allCases.map(\.letter) == ["R", "F", "C"])
        #expect(GameFamily.allCases.map(\.displayName) == ["Retail", "Forever", "Classic"])
        #expect(GameFamily.classic.flavors == [.vanilla, .tbc, .wrath, .titan, .cata, .mists])
        #expect(Flavor.forever.fallbackFlavor == .mainline)
        #expect(Flavor.mainline.fallbackFlavor == nil && Flavor.mists.fallbackFlavor == nil)
        #expect(Flavor.from(releaseJSONName: "BCC") == .tbc)
        #expect(Flavor.from(releaseJSONName: "camelot") == .forever)
        #expect(Flavor.from(releaseJSONName: "classic") == .vanilla)
        #expect(Flavor.from(releaseJSONName: "unknown") == nil)
    }

    @Test func storageValueRoundTrips() {
        let flavors: Set<Flavor> = [.mists, .mainline, .forever]
        #expect(flavors.storageValue == "mainline,forever,mists")
        #expect(Set<Flavor>(storageValue: "mists,mainline,someday,forever") == flavors)
        #expect(Set<Flavor>(storageValue: "").isEmpty)
    }

    // MARK: release.json

    @Test func quickFlaskShipsRetailForeverAndClassic() throws {
        let json = try ReleaseJSON(data: fixtureData("github/quickflask-release-3.17.1.json"))
        #expect(json.availableFlavors == quickFlaskFlavors)
        #expect(json.availableFlavors.families == [.retail, .forever, .classic])
    }

    @Test func nolibBuildsAndUnknownNamesDontCount() {
        let json = ReleaseJSON(releases: [
            .init(filename: "a-nolib.zip", nolib: true, metadata: [.init(flavor: "forever", interface: 16001)]),
            .init(filename: "a.zip", nolib: false, metadata: [.init(flavor: "mainline", interface: 120100), .init(flavor: "next", interface: 1)]),
        ])
        #expect(json.availableFlavors == [.mainline])
    }

    @Test func checkStoresAndReturnsEveryFlavor() async throws {
        let http = RedirectingHTTPClient()
        let repo = quickFlask.identifier
        http.redirect("https://github.com/\(repo)/releases/latest", to: "https://github.com/\(repo)/releases/tag/3.17.1")
        http.stub("https://github.com/\(repo)/releases/download/3.17.1/release.json", body: try fixtureData("github/quickflask-release-3.17.1.json"))
        let source = GitHub(http: http)

        let check = await source.latest.check(quickFlask, flavor: .forever)
        #expect(check.status == .supported(version: "3.17.1"))
        #expect(check.availableFlavors == quickFlaskFlavors)
        #expect(check.families == [.retail, .forever, .classic])
        #expect(http.apiRequests.isEmpty)
        #expect(await source.latest.store.availableFlavors(for: quickFlask) == quickFlaskFlavors)

        // Another flavor's stored answer reads the same per-repo flavors, without a request.
        http.reset()
        #expect(await source.latest.check(quickFlask, flavor: .mists, policy: .revalidateIfStale).availableFlavors == quickFlaskFlavors)
        #expect(http.requests.isEmpty)
        #expect(await source.latest.check(quickFlask, flavor: .forever, policy: .preferStored).availableFlavors == quickFlaskFlavors)
    }

    /// A verdict stored before flavor lists existed (tag known, no flavors) gets its list from
    /// the tag's release.json on the next non-stored check, and isn't "fresh" for visible rows.
    @Test func verdictWithoutFlavorsFetchesThemOnce() async throws {
        let http = RedirectingHTTPClient()
        let repo = quickFlask.identifier
        http.stub("https://github.com/\(repo)/releases/download/3.17.1/release.json", body: try fixtureData("github/quickflask-release-3.17.1.json"))
        let source = GitHub(http: http)
        await source.latest.store.set([SupportRecord(ref: quickFlask, status: .supported(version: "3.17.1"), tag: "3.17.1", checkedAt: .now)], flavor: .forever)
        #expect(await source.latest.hasFreshAnswer(for: quickFlask, flavor: .forever) == false)

        // Stored-only reads never fetch.
        #expect(await source.latest.check(quickFlask, flavor: .forever, policy: .preferStored).availableFlavors == nil)
        #expect(http.requests.isEmpty)

        let check = await source.latest.check(quickFlask, flavor: .forever, policy: .revalidateIfStale)
        #expect(check.availableFlavors == quickFlaskFlavors)
        #expect(http.apiRequests.isEmpty)
        #expect(http.requests.count == 1)
        #expect(await source.latest.hasFreshAnswer(for: quickFlask, flavor: .forever))

        http.reset()
        _ = await source.latest.check(quickFlask, flavor: .forever, policy: .revalidateIfStale)
        #expect(http.requests.isEmpty)
    }

    @Test func noReleaseJSONLeavesFlavorsUnknown() async {
        let http = RedirectingHTTPClient()
        http.publishLatest("o/r", tag: "v1", flavors: nil)
        let source = GitHub(http: http)
        let check = await source.latest.check(AddonRef(source: .github, identifier: "o/r"), flavor: .forever)
        #expect(check.status == .needsDownload)
        #expect(check.availableFlavors == nil)
    }

    @Test func inspectionNeverReplacesReleaseJSON() async throws {
        let cache = SupportCache(database: try MetadataDatabase.inMemory())
        await cache.setAvailableFlavors([.forever], tag: "v1", source: .inspection, for: quickFlask)
        #expect(await cache.storedFlavors(for: quickFlask)?.source == .inspection)
        await cache.setAvailableFlavors(quickFlaskFlavors, tag: "v1", source: .releaseJSON, for: quickFlask)
        await cache.setAvailableFlavors([.vanilla], tag: "v2", source: .inspection, for: quickFlask)
        #expect(await cache.availableFlavors(for: quickFlask) == quickFlaskFlavors)
        // A later release without release.json clears what an older one said.
        await cache.setAvailableFlavors(nil, tag: "v3", source: .releaseJSON, for: quickFlask)
        #expect(await cache.availableFlavors(for: quickFlask) == nil)
    }

    @Test func migrationBackfillsFromStoredReleaseJSON() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: MetadataDatabase.fileName)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK)
        func exec(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql.prefix(60))") }
        for step in MetadataDatabase.migrations.prefix(4) { exec(step) }
        exec("PRAGMA user_version = 4")
        let json = String(decoding: try JSONEncoder().encode(ReleaseJSON(data: fixtureData("github/quickflask-release-3.17.1.json"))), as: UTF8.self)
        exec("INSERT INTO repo_meta(full_name, latest_tag, tag_checked_at) VALUES ('test/quickflask', '3.17.1', 1)")
        exec("INSERT INTO release_json(full_name, tag, json, fetched_at) VALUES ('test/QuickFlask', '3.17.1', '\(json)', 1)")
        exec("INSERT INTO repo_meta(full_name, latest_tag, tag_checked_at) VALUES ('o/bare', 'v1', 1)")
        exec("INSERT INTO release_json(full_name, tag, json, fetched_at) VALUES ('o/bare', 'v1', NULL, 1)")
        sqlite3_close(db)

        let database = try MetadataDatabase(url: url)
        #expect(try await database.schemaVersion() == MetadataDatabase.migrations.count)
        let cache = SupportCache(database: database)
        #expect(await cache.availableFlavors(for: quickFlask) == quickFlaskFlavors)
        #expect(await cache.storedFlavors(for: quickFlask)?.tag == "3.17.1")
        #expect(await cache.availableFlavors(for: AddonRef(source: .github, identifier: "o/bare")) == nil)
    }

    // MARK: Inspection

    @Test func flavorsFromTheTocsPresent() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        func folder(_ name: String, _ tocs: [String: String]) throws -> URL {
            let url = dir.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (file, interface) in tocs {
                try Data("## Interface: \(interface)\n## Title: \(name)\n".utf8).write(to: url.appending(path: file))
            }
            return url
        }
        let suffixed = try folder("Multi", ["Multi_Mainline.toc": "120100", "Multi_Camelot.toc": "16001", "Multi_Mists.toc": "50504"])
        #expect(ZipInspector.availableFlavors(addonFolders: [suffixed]) == [.mainline, .forever, .mists])
        let mainlineForForever = try folder("Shared", ["Shared_Mainline.toc": "120100, 16001"])
        #expect(ZipInspector.availableFlavors(addonFolders: [mainlineForForever]) == [.mainline, .forever])
        let base = try folder("Base", ["Base.toc": "120100, 11508"])
        #expect(ZipInspector.availableFlavors(addonFolders: [base]) == [.mainline, .vanilla])
        let classic = try folder("Old", ["Old_Classic.toc": "", "Old.toc": "16001"])
        #expect(ZipInspector.availableFlavors(addonFolders: [classic]) == [.vanilla, .forever])
        #expect(ZipInspector.availableFlavors(addonFolders: [suffixed, base]).families == [.retail, .forever, .classic])
    }

    @Test func installRecordsInspectedFlavorsWithoutReleaseJSON() async throws {
        let h = try await ManagerHarness()
        let ref = AddonRef(source: .github, identifier: "Test/Addon")
        try h.publish("Test/Addon", [("v1", 1, 1)])
        // The harness's latest release has no release.json on the free route…
        h.http.publishLatest("Test/Addon", tag: "v1", flavors: nil)
        try await h.manager.install(ref, into: h.installation)
        // …so the zip's base TOC (interface 16001) is what's known.
        #expect(await h.manager.availableFlavors(for: [ref])[ref] == [.forever])
        let details = try await h.manager.details(for: ref, in: h.installation)
        #expect(details.availableFlavors == [.forever])
    }

    // MARK: Hide incompatible

    @Test func hideRulePerFamily() {
        let classicOnly: Set<GameFamily> = [.classic]
        let retailOnly: Set<GameFamily> = [.retail]
        let all: Set<GameFamily> = [.retail, .forever, .classic]
        let unsupported = SupportStatus.unsupported
        // Forever: only classic-only goes; Retail-only and unknown stay.
        #expect(Flavor.forever.hidesAsIncompatible(families: classicOnly, support: unsupported))
        #expect(!Flavor.forever.hidesAsIncompatible(families: retailOnly, support: unsupported))
        #expect(!Flavor.forever.hidesAsIncompatible(families: nil, support: .unknown))
        #expect(!Flavor.forever.hidesAsIncompatible(families: all, support: .supported(version: "1")))
        // Retail: anything without a Retail build.
        #expect(Flavor.mainline.hidesAsIncompatible(families: classicOnly, support: unsupported))
        #expect(Flavor.mainline.hidesAsIncompatible(families: [.forever], support: unsupported))
        #expect(!Flavor.mainline.hidesAsIncompatible(families: retailOnly, support: .supported(version: "1")))
        // Classics: anything without a Classic build.
        #expect(Flavor.mists.hidesAsIncompatible(families: retailOnly, support: unsupported))
        #expect(!Flavor.mists.hidesAsIncompatible(families: classicOnly, support: unsupported))
        #expect(!Flavor.vanilla.hidesAsIncompatible(families: nil, support: .needsDownload))
        // No releases at all is never worth showing.
        #expect(Flavor.forever.hidesAsIncompatible(families: nil, support: .noReleases))
    }

    @Test func availabilitySentences() {
        func sentence(_ flavors: Set<Flavor>?, _ flavor: Flavor = .forever) -> String {
            GameAvailability.sentence(availableFlavors: flavors, for: flavor)
        }
        #expect(sentence(quickFlaskFlavors) == "Has a Forever build")
        #expect(sentence([.mainline]) == "Retail build only: may work on Forever; it will show as out of date")
        #expect(sentence([.vanilla, .mists]) == "Classic only: won't load on Forever")
        #expect(sentence(nil) == "Not checked yet")
        #expect(sentence([.vanilla], .mists) == "Has Classic builds, but none for Mists Classic")
        #expect(sentence([.mainline], .mainline) == "Has a Retail build")
        #expect(sentence([.forever], .mainline) == "No Retail build")
    }
}
