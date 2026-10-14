import Foundation
import Testing
@testable import AddonKit

/// WoWInterface and Tukui, and turning sources on and off (docs/features/sources.md).
@Suite struct SourceParsingTests {
    @Test func hostedRefs() {
        let wowi = AddonRef(source: .wowinterface, identifier: "3826")
        #expect(AddonRef(parsing: "wowinterface:3826") == wowi)
        #expect(AddonRef(parsing: "https://www.wowinterface.com/downloads/info3826-CTMod.html") == wowi)
        #expect(AddonRef(parsing: "wowinterface.com/downloads/fileinfo.php?s=abc&id=3826") == wowi)
        #expect(AddonRef(parsing: "https://www.wowinterface.com/downloads/download3826-CTMod") == wowi)
        #expect(AddonRef(parsing: "wowinterface:abc") == nil)
        #expect(AddonRef(parsing: "https://www.wowinterface.com/forums/") == nil)

        let elvui = AddonRef(source: .tukui, identifier: "elvui")
        #expect(AddonRef(parsing: "tukui:ElvUI") == elvui)
        #expect(AddonRef(parsing: "https://tukui.org/elvui") == elvui)
        #expect(AddonRef(parsing: "tukui.org/elvui/extra") == nil)

        // GitHub keeps working, and wins for `owner/repo`.
        #expect(AddonRef(parsing: "BigWigsMods/BigWigs") == AddonRef(source: .github, identifier: "BigWigsMods/BigWigs"))
    }

    @Test func keysRoundTrip() {
        let refs = [
            AddonRef(source: .github, identifier: "Owner/Repo"),
            AddonRef(source: .wowinterface, identifier: "3826"),
            AddonRef(source: .tukui, identifier: "elvui"),
        ]
        #expect(refs.map(\.key) == ["Owner/Repo", "wowinterface:3826", "tukui:elvui"])
        for ref in refs { #expect(AddonRef(key: ref.key) == ref) }
    }

    @Test func wowInterfaceListing() throws {
        let entries = try WoWInterface().entries(fromListing: fixtureData("sources/wowinterface-filelist.json"))
        // The entry with a non-numeric ID is dropped.
        #expect(entries.map(\.fullName) == ["wowinterface:101", "wowinterface:102", "wowinterface:103"])
        let ledger = try #require(entries.first)
        #expect(ledger.ref == AddonRef(source: .wowinterface, identifier: "101"))
        #expect(ledger.owner == "Scribe")
        #expect(ledger.listedFlavors == [.mainline])
        #expect(ledger.screenshots == [URL(string: "https://cdn-wow.mmoui.com/preview/pvw101.jpg")!])
        #expect(entries[1].listedFlavors == [.vanilla])
        #expect(entries[2].listedFlavors == nil)
    }

    @Test func tukuiListingAndFiles() throws {
        let data = try fixtureData("sources/tukui-addons.json")
        let entry = try #require(try Tukui().entries(fromListing: data).first)
        #expect(entry.ref == AddonRef(source: .tukui, identifier: "elvui"))
        #expect(entry.listedFlavors == [.mainline, .tbc, .vanilla, .mists])
        let file = try #require(try Tukui().files(from: data)["elvui"])
        #expect(file.version == "16.00")
        #expect(file.screenshots.count == 2)
        #expect(file.publishedAt == Date(timeIntervalSince1970: 1_791_849_600))
    }

    @Test func bbCode() {
        let text = "[SIZE=\"4\"][B]Title[/B][/SIZE]\r\n[url=https://x.test]site[/url] and [i]more[/i]\r\n[list]\r\n[*]one\r\n[*]two\r\n[/list]\r\n[COLOR=red]red[/COLOR]"
        #expect(BBCode.markdown(text) == "**Title**\n[site](https://x.test) and *more*\n\n- one\n- two\n\nred")
    }
}

@Suite struct HostedSourceManagerTests {
    static let listing = "https://api.mmoui.com/v3/game/WOW/filelist.json"
    static let details = "https://api.mmoui.com/v3/game/WOW/filedetails/101.json"
    static let tukui = "https://api.tukui.org/v1/addons"
    static let ledger = AddonRef(source: .wowinterface, identifier: "101")

    /// Stubs both listings, and file 101 at `version` with a zip whose TOC has `interface`.
    func stub(_ h: ManagerHarness, version: String = "2.0", interface: Int = 16001) throws {
        h.http.stub(Self.listing, body: try fixtureData("sources/wowinterface-filelist.json"))
        h.http.stub(Self.tukui, body: try fixtureData("sources/tukui-addons.json"))
        let download = "https://cdn.wowinterface.com/downloads/getfile.php?id=101&v=\(version)"
        let json = #"[{"UID":"101","UIName":"Quest Ledger","UIAuthorName":"Scribe","UIVersion":"\#(version)","UIDate":"1790000000000","UIFileName":"QuestLedger-\#(version).zip","UIDownload":"\#(download)","UIDescription":"[b]Tracks[/b] quests","UIChangeLog":"Fixed things in \#(version)"}]"#
        h.http.stub(Self.details, text: json)
        let zip = try makeTestZip([
            .directory("QuestLedger"),
            .file("QuestLedger/QuestLedger.toc", "## Interface: \(interface)\n## Title: Quest Ledger\n"),
        ], named: "ledger-\(version).zip", in: makeTempDirectory())
        h.transport.stub(URL(string: download)!, try Data(contentsOf: zip))
    }

    func results(_ h: ManagerHarness, _ text: String) async -> [SearchResult] {
        var last: [SearchResult] = []
        for await batch in h.manager.search(SearchQuery(text: text, flavor: .forever, hideIncompatible: false), in: h.installation) {
            last = batch
        }
        return last
    }

    func refresh(_ h: ManagerHarness, force: Bool = true) async {
        for await _ in h.manager.refresh(in: h.installation, force: force) {}
    }

    @Test func sourcesStartOnAndPersist() async throws {
        let h = try await ManagerHarness()
        #expect(await h.manager.sources().map(\.source) == [.github, .wowinterface, .tukui])
        #expect(await h.manager.sources().allSatisfy(\.isEnabled))
        try await h.manager.setSource(.wowinterface, enabled: false)
        let reopened = await h.reopen()
        #expect(await reopened.sources().first { $0.source == .wowinterface }?.isEnabled == false)
        #expect(await reopened.sources().first { $0.source == .tukui }?.isEnabled == true)
    }

    @Test func refreshImportsListingsAndSearchFindsThem() async throws {
        let h = try await ManagerHarness()
        try stub(h)
        await refresh(h)
        let found = await results(h, "quest ledger")
        let ledger = try #require(found.first { $0.id == Self.ledger })
        #expect(ledger.owner == "Scribe")
        #expect(ledger.availableFlavors == [.mainline])
        #expect(ledger.support == .needsDownload)
        #expect(await results(h, "elvui").contains { $0.id == AddonRef(source: .tukui, identifier: "elvui") })
        // A direct reference works too.
        #expect(await results(h, "wowinterface:101").first?.id == Self.ledger)
    }

    @Test func aSourceThatIsOffIsHiddenAndNotDownloaded() async throws {
        let h = try await ManagerHarness()
        try stub(h)
        await refresh(h)
        try await h.manager.setSource(.wowinterface, enabled: false)
        #expect(await results(h, "quest ledger").isEmpty)
        #expect(await results(h, "wowinterface:101").isEmpty)
        #expect(await h.manager.browse(in: h.installation).recent.allSatisfy { $0.id.source != .wowinterface })

        h.http.reset()
        await refresh(h)
        #expect(!h.http.urls.contains(Self.listing))
        #expect(h.http.urls.contains(Self.tukui))

        try await h.manager.setSource(.wowinterface, enabled: true)
        #expect(await results(h, "quest ledger").contains { $0.id == Self.ledger })
    }

    @Test func installUpdateAndSourceOff() async throws {
        let h = try await ManagerHarness()
        try stub(h)
        await refresh(h)
        let installed = try await h.manager.install(Self.ledger, into: h.installation)
        #expect(installed.version == "2.0")
        #expect(installed.folders == ["QuestLedger"])
        #expect(await h.manager.availableFlavors(for: [Self.ledger])[Self.ledger] == [.forever])
        #expect(try await h.manager.checkForUpdates(in: h.installation)[Self.ledger] == .upToDate)

        // Off: gone from search results, still installed and still checked for updates.
        try await h.manager.setSource(.wowinterface, enabled: false)
        try stub(h, version: "2.1")
        let found = await results(h, "quest ledger")
        #expect(found.map(\.id) == [Self.ledger])
        #expect(found.first?.installed != nil)
        guard case .available(let release) = try await h.manager.checkForUpdates(in: h.installation)[Self.ledger] else {
            Issue.record("expected an update")
            return
        }
        #expect(release.version == "2.1")
        var updated: InstalledAddon?
        for await event in h.manager.update([Self.ledger], in: h.installation) {
            if case .done(let addon) = event { updated = addon }
        }
        #expect(updated?.version == "2.1")
    }

    @Test func zipDecidesForeverSupport() async throws {
        let h = try await ManagerHarness()
        // A Retail-only zip: no Forever build, but the Retail build installs on request.
        try stub(h, interface: 120100)
        await #expect(throws: AddonError.self) { try await h.manager.install(Self.ledger, into: h.installation) }
        let release = try await h.manager.resolve(Self.ledger, for: h.installation, channel: .stable, allowFamilyFallback: true)
        #expect(release.flavorBuild == .mainline)
        #expect(await h.manager.availableFlavors(for: [Self.ledger])[Self.ledger] == [.mainline])
    }

    @Test func hostedDetails() async throws {
        let h = try await ManagerHarness()
        try stub(h)
        await refresh(h)
        let details = try await h.manager.details(for: Self.ledger, in: h.installation)
        #expect(details.name == "Quest Ledger")
        #expect(details.owner == "Scribe")
        #expect(details.readme == "**Tracks** quests")
        #expect(details.latestVersion == "2.0")
        #expect(details.latestChangelog == "Fixed things in 2.0")
        #expect(details.repositoryURL == URL(string: "https://www.wowinterface.com/downloads/info101")!)
        #expect(details.screenshots == [URL(string: "https://cdn-wow.mmoui.com/preview/pvw101.jpg")!])
    }
}
