import Foundation
import Testing
@testable import AddonKit

/// Unmanaged folders: which TOC is read, adoption suggestions, grouping and removal. Offline:
/// the Questie and QuestieDB folders from a real Forever beta install are recreated in a temp dir.
@Suite struct AdoptionTests {
    let root: URL
    let installRoot: URL
    let http = StubHTTPClient()
    let transport = StubDownloadTransport()
    let manager: AddonManager

    static let questie = AddonRef(source: .github, identifier: "Questie/Questie")
    static let questieRow = CatalogueEntry(
        id: "1", name: "Questie", fullName: "Questie/Questie", url: URL(string: "https://github.com/Questie/Questie")!,
        lastUpdated: Date(timeIntervalSince1970: 1_800_000_000), curseID: 334372, wagoID: "qv634BKb"
    )

    init() throws {
        root = try makeTempDirectory()
        installRoot = root.appending(path: "World of Warcraft/_classic_beta_", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: installRoot.appending(path: "Interface/AddOns"), withIntermediateDirectories: true)
        manager = AddonManager(
            directories: AppDirectories(root: root.appending(path: "AppData")),
            http: http,
            downloadTransport: transport,
            locator: InstallationLocator(baseFolders: [], findApps: { [] }),
            installer: Installer(trash: { try FileManager.default.removeItem(at: $0) }),
            keychain: KeychainStore(service: "AddonKitTests-\(UUID().uuidString)"),
            environment: [:]
        )
    }

    var addonsDirectory: URL { installRoot.appending(path: "Interface/AddOns", directoryHint: .isDirectory) }

    func folder(_ name: String, _ files: [String: String]) throws {
        let dir = addonsDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (file, contents) in files { try Data(contents.utf8).write(to: dir.appending(path: file)) }
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: addonsDirectory.appending(path: name).path(percentEncoded: false))
    }

    /// The user's Questie and QuestieDB folders.
    func makeQuestie() throws {
        func toc(_ interface: Int) -> String {
            "## Interface: \(interface)\n## Title: Questie|cFF00FF00 v12.0.4|r\n## Author: Aero\n## Notes: A quest helper\n## X-Curse-Project-ID: 334372\n## X-Wago-ID: qv634BKb\n"
        }
        try folder("Questie", [
            "Questie.toc": "## Interface: 00000\n## Title: Questie|cFFFF0000 game client not supported|r\n",
            "Questie_Camelot.toc": toc(16001),
            "Questie_Vanilla.toc": toc(11507),
            "Questie_TBC.toc": toc(20505),
            "Questie_Wrath.toc": toc(30405),
            "Questie_Mists.toc": toc(50501),
        ])
        try folder("QuestieDB", [
            "QuestieDB_Camelot.toc": "## Interface: 16001\n## Title: QuestieDB\n",
            "QuestieDB_Forever.toc": "## Interface: 16001\n## Title: QuestieDB\n",
            "QuestieDB_Vanilla.toc": "## Interface: 11507\n## Title: QuestieDB\n",
        ])
    }

    func installation() async throws -> Installation {
        try await manager.addInstallation(at: installRoot)
    }

    func importCatalogue(_ entries: [CatalogueEntry]) async throws {
        _ = try await manager.database.importCatalogue(entries, etag: nil, at: Date())
    }

    func unmanaged(_ statuses: [AddonStatus]) -> [UnmanagedFolder] { statuses.compactMap(\.unmanagedFolder) }

    // MARK: - Which TOC

    @Test func readsTheTocForeverLoads() throws {
        try makeQuestie()
        let questie = UnmanagedFolder(reading: "Questie", in: addonsDirectory, flavor: .forever)
        #expect(questie.tocFile == "Questie_Camelot.toc")
        #expect(questie.title == "Questie")
        #expect(questie.version == "v12.0.4")
        #expect(questie.toc?.author == "Aero")
        #expect(questie.supportsFlavor && questie.isLoaded)
        // Hints come from every TOC, de-duplicated.
        #expect(questie.hints.curseIDs == [334372])
        #expect(questie.hints.wagoIDs == ["qv634BKb"])
        #expect(questie.hints.titles == ["Questie game client not supported", "Questie"])

        let db = UnmanagedFolder(reading: "QuestieDB", in: addonsDirectory, flavor: .forever)
        #expect(db.tocFile == "QuestieDB_Camelot.toc")
        #expect(db.supportsFlavor)
    }

    @Test func folderTheFlavorDoesNotLoad() throws {
        try makeQuestie()
        // Retail has no Questie TOC, so it reads the base fallback, which it doesn't support.
        let questie = UnmanagedFolder(reading: "Questie", in: addonsDirectory, flavor: .mainline)
        #expect(questie.tocFile == "Questie.toc")
        #expect(questie.title == "Questie game client not supported")
        #expect(questie.version == nil)
        #expect(questie.isLoaded && !questie.supportsFlavor)

        // No base TOC at all: the first TOC is shown, marked as not loaded.
        let db = UnmanagedFolder(reading: "QuestieDB", in: addonsDirectory, flavor: .mainline)
        #expect(db.tocFile == "QuestieDB_Camelot.toc")
        #expect(!db.isLoaded && !db.supportsFlavor)

        #expect(UnmanagedFolder(reading: "Questie", in: addonsDirectory, flavor: .vanilla).tocFile == "Questie_Vanilla.toc")
    }

    /// The same rule as `ZipInspector`: the client loads `_Mainline` ahead of the base TOC, and
    /// it counts for Forever only with a Forever interface.
    @Test func sharedTocCountsOnlyInRange() throws {
        try folder("Shared", [
            "Shared.toc": "## Interface: 16001\n## Title: Base\n",
            "Shared_Mainline.toc": "## Interface: 120001\n## Title: Retail\n",
        ])
        let shared = UnmanagedFolder(reading: "Shared", in: addonsDirectory, flavor: .forever)
        #expect(shared.tocFile == "Shared_Mainline.toc")
        #expect(shared.isLoaded && !shared.supportsFlavor)

        try folder("InRange", ["InRange.toc": "## Interface: 11508\n", "InRange_Mainline.toc": "## Interface: 120001, 16001\n"])
        let inRange = UnmanagedFolder(reading: "InRange", in: addonsDirectory, flavor: .forever)
        #expect(inRange.tocFile == "InRange_Mainline.toc" && inRange.supportsFlavor)
    }

    @Test(arguments: [
        ("Questie v12.0.4", "Questie", "v12.0.4"),
        ("ElvUI 13.50", "ElvUI", "13.50"),
        ("Plater (v2.1-beta)", "Plater", "v2.1-beta"),
        ("Leatrix Plus 1.15.80 - Forever", "Leatrix Plus - Forever", "1.15.80"),
    ])
    func versionFromTitle(title: String, cleaned: String, version: String) throws {
        let split = try #require(Toc.splitVersion(fromTitle: title))
        #expect(split.title == cleaned)
        #expect(split.version == version)
    }

    @Test(arguments: ["Details! Damage Meter", "WeakAuras 2", "v1.0", "Questie game client not supported"])
    func titlesWithoutVersion(title: String) {
        #expect(Toc.splitVersion(fromTitle: title) == nil)
    }

    @Test func declaredVersionWinsUnlessUnexpanded() {
        #expect(Toc(parsing: "## Title: A v1.0\n## Version: 2.0\n").displayVersion == "2.0")
        #expect(Toc(parsing: "## Title: A v1.0\n## Version: @project-version@\n").displayVersion == "v1.0")
        #expect(Toc(parsing: "## Title: A v1.0\n").displayTitle == "A")
    }

    // MARK: - Suggestions

    static func entry(_ fullName: String, name: String? = nil, curse: Int? = nil, wago: String? = nil, wowi: Int? = nil, day: Int = 0) -> CatalogueEntry {
        CatalogueEntry(
            id: fullName, name: name ?? String(fullName.split(separator: "/").last!), fullName: fullName,
            url: URL(string: "https://github.com/\(fullName)")!, lastUpdated: Date(timeIntervalSince1970: Double(day) * 86_400),
            curseID: curse, wagoID: wago, wowiID: wowi
        )
    }

    @Test func everySuggestionSource() {
        let index = AdoptionIndex(entries: [
            Self.entry("a/Linked"),
            Self.entry("c/Cursed", curse: 11),
            Self.entry("w/Wagoed", wago: "abc"),
            Self.entry("i/Interfaced", wowi: 22),
            Self.entry("n/some-repo", name: "Folder"),
            Self.entry("t/other-repo", name: "Nice Title"),
            Self.entry("r/Folder", name: "Something Else"),
        ])
        let hints = TocHints(
            githubRefs: [AddonRef(source: .github, identifier: "a/Linked")], curseIDs: [11], wagoIDs: ["ABC"],
            wowInterfaceIDs: [22], titles: ["Nice Title"]
        )
        let candidates = index.candidates(folder: "Folder", hints: hints)
        #expect(candidates.map(\.ref.identifier) == ["a/Linked", "c/Cursed", "w/Wagoed", "i/Interfaced", "n/some-repo"])
        #expect(candidates.map(\.source) == [.tocLink, .curseForge, .wago, .wowInterface, .catalogueName])
        #expect(candidates[1].reason == "Matched CurseForge project 11")
        #expect(candidates[2].reason == "Matched Wago project ABC")
        #expect(candidates[3].reason == "Matched WoWInterface project 22")
        #expect(candidates[4].reason == "Matched folder name")
        #expect(candidates.isAmbiguous)

        // Past the cap: title and repo-name matches.
        let names = index.candidates(folder: "Folder", hints: TocHints(titles: ["Nice Title"]))
        #expect(names.map(\.ref.identifier) == ["n/some-repo", "t/other-repo", "r/Folder"])
        #expect(names.map(\.reason) == ["Matched folder name", "Matched TOC title “Nice Title”", "Matched repository name"])
        #expect(names.map(\.confidence) == [.medium, .medium, .low])
    }

    @Test func tocLinkFromXGithub() {
        let hints = TocHints([Toc(parsing: "## X-Github: https://github.com/Owner/Repo\n")])
        #expect(hints.githubRefs == [AddonRef(source: .github, identifier: "Owner/Repo")])
        let candidates = AdoptionIndex(entries: []).candidates(folder: "X", hints: hints)
        #expect(candidates.first?.reason == "TOC links to github.com/Owner/Repo")
        #expect(candidates.first?.name == "Repo")
    }

    @Test func ambiguousIDsListEveryCandidateNewestFirst() {
        let index = AdoptionIndex(entries: [Self.entry("fork/Questie", curse: 334372, day: 1), Self.entry("Questie/Questie", curse: 334372, day: 9)])
        let candidates = index.candidates(folder: "Questie", hints: TocHints(curseIDs: [334372]))
        #expect(candidates.map(\.ref.identifier) == ["Questie/Questie", "fork/Questie"])
        #expect(candidates.isAmbiguous)

        // One strong match and weaker ones isn't ambiguous.
        let single = AdoptionIndex(entries: [Self.entry("Questie/Questie", curse: 334372), Self.entry("x/Questie")])
            .candidates(folder: "Questie", hints: TocHints(curseIDs: [334372]))
        #expect(single.count == 2)
        #expect(!single.isAmbiguous)
    }

    @Test func questieSuggestionThroughTheManager() async throws {
        try makeQuestie()
        try await importCatalogue([Self.questieRow])
        let installation = try await installation()

        let candidates = await manager.adoptionCandidates(folder: "Questie", in: installation)
        #expect(candidates.map(\.ref) == [Self.questie])
        #expect(candidates.first?.reason == "Matched CurseForge project 334372")
        #expect(candidates.first?.confidence == .high)

        let rows = unmanaged(try await manager.addons(in: installation))
        #expect(rows.map(\.folder) == ["Questie", "QuestieDB"])
        #expect(rows[0].title == "Questie" && rows[0].version == "v12.0.4")
        #expect(rows[0].suggestedRef == Self.questie)
        // QuestieDB has no hints and no catalogue row: its own row, no suggestion.
        #expect(rows[1].folders == ["QuestieDB"])
        #expect(rows[1].suggestedRef == nil)
    }

    // MARK: - Grouping

    @Test func groupsFoldersTheReleaseShips() async throws {
        try makeQuestie()
        try await importCatalogue([Self.questieRow])
        let installation = try await installation()

        await manager.database.setReleaseFolders(["Questie", "QuestieDB"], tag: "v12.0.4", for: "Questie/Questie", at: Date())
        let grouped = unmanaged(try await manager.addons(in: installation))
        #expect(grouped.count == 1)
        #expect(grouped[0].folder == "Questie")
        #expect(grouped[0].folders == ["Questie", "QuestieDB"])
        #expect(grouped[0].suggestedRef == Self.questie)

        // A release that ships only Questie leaves QuestieDB on its own.
        await manager.database.setReleaseFolders(["Questie"], tag: "v12.0.5", for: "Questie/Questie", at: Date())
        let separate = unmanaged(try await manager.addons(in: installation))
        #expect(separate.map(\.folders) == [["Questie"], ["QuestieDB"]])
    }

    @Test func groupsFoldersSuggestingTheSameRepo() {
        let ref = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs")
        let candidate = AdoptionCandidate(ref: ref, name: "BigWigs", reason: "TOC links to github.com/BigWigsMods/BigWigs", source: .tocLink)
        let folders = [
            UnmanagedFolder(folder: "BigWigs", candidates: [candidate]),
            UnmanagedFolder(folder: "BigWigs_Core", candidates: [candidate]),
            UnmanagedFolder(folder: "Other"),
        ]
        let grouped = AdoptionIndex.group(folders, releaseFolders: [:])
        #expect(grouped.map(\.folders) == [["BigWigs", "BigWigs_Core"], ["Other"]])

        // An ambiguous folder isn't pulled into anyone's group.
        let other = AdoptionCandidate(ref: AddonRef(source: .github, identifier: "x/BigWigs"), name: "BigWigs", reason: "r", source: .tocLink)
        let ambiguous = UnmanagedFolder(folder: "BigWigs_Plugins", candidates: [candidate, other])
        #expect(AdoptionIndex.group([folders[0], ambiguous], releaseFolders: [:]).map(\.folders) == [["BigWigs"], ["BigWigs_Plugins"]])
    }

    @Test func previewListsTheFoldersItReplaces() async throws {
        try makeQuestie()
        try await importCatalogue([Self.questieRow])
        let installation = try await installation()
        let zip = try makeAddonZip(folders: ["Questie", "QuestieDB"], marker: "v12.0.4", named: "Questie-v12.0.4.zip", in: makeTempDirectory())
        // No release.json: release selection inspects the zip (over HTTP), then the install
        // downloads it (through the transport).
        transport.stub(URL(string: "https://downloads.test/Questie-v12.0.4.zip")!, try Data(contentsOf: zip))
        http.stub("https://downloads.test/Questie-v12.0.4.zip", body: try Data(contentsOf: zip))
        let releases: [[String: Any]] = [[
            "id": 7, "tag_name": "v12.0.4", "name": "v12.0.4", "draft": false, "prerelease": false,
            "published_at": "2026-10-01T12:00:00Z", "body": "",
            "assets": [["id": 70, "name": "Questie-v12.0.4.zip", "state": "uploaded", "size": 100,
                        "content_type": "application/zip", "browser_download_url": "https://downloads.test/Questie-v12.0.4.zip"]],
        ]]
        http.stub("https://api.github.com/repos/Questie/Questie/releases?per_page=10", body: try JSONSerialization.data(withJSONObject: releases))

        let preview = try await manager.adoptionPreview(for: Self.questie, folders: ["Questie"], in: installation)
        #expect(preview.release.version == "v12.0.4")
        #expect(preview.replaces == ["Questie", "QuestieDB"])
        #expect(preview.adds.isEmpty && preview.conflicts.isEmpty && preview.notCovered.isEmpty)
        // The preview taught the core what the release ships, so the list groups them now.
        #expect(unmanaged(try await manager.addons(in: installation)).map(\.folders) == [["Questie", "QuestieDB"]])

        let adopted = try await manager.adopt(preview.release, in: installation)
        #expect(adopted.folders == ["Questie", "QuestieDB"])
        #expect(unmanaged(try await manager.addons(in: installation)).isEmpty)
    }

    // MARK: - Removal

    @Test func removeUnmanagedRefusesWithoutTouchingAnything() async throws {
        try makeQuestie()
        try folder("Blizzard_UI", ["Blizzard_UI.toc": ""])
        try folder("Owned", ["Owned.toc": ""])
        try Data().write(to: addonsDirectory.appending(path: "stray.txt"))
        let installation = try await installation()
        try await manager.store.upsert(InstalledAddon(
            id: AddonRef(source: .github, identifier: "o/Owned"), name: "Owned", folders: ["Owned"], version: "1",
            releaseID: 1, assetName: "a.zip", publishedAt: Date(), installedAt: Date()
        ), in: installation)

        for (folder, reason) in [
            ("Blizzard_UI", "belongs to the game"),
            ("owned", "is managed as o/Owned; uninstall that instead"),
            ("../Questie", "isn't a folder in Interface/AddOns"),
            ("..", "isn't a folder in Interface/AddOns"),
            ("Questie/Questie.toc", "isn't a folder in Interface/AddOns"),
            ("Missing", "isn't in Interface/AddOns"),
            ("stray.txt", "isn't in Interface/AddOns"),
        ] {
            await #expect(throws: AddonError.cannotRemove(folder: folder, reason: reason)) {
                try await manager.removeUnmanaged(folders: ["QuestieDB", folder], from: installation)
            }
        }
        // Each refusal came before any move.
        #expect(exists("QuestieDB") && exists("Questie") && exists("Owned") && exists("Blizzard_UI"))
    }

    @Test func removeUnmanagedMovesAGroup() async throws {
        try makeQuestie()
        let installation = try await installation()
        let removed = try await manager.removeUnmanaged(folders: ["questie", "QuestieDB", "Questie"], from: installation)
        #expect(removed == ["Questie", "QuestieDB"])
        #expect(!exists("Questie") && !exists("QuestieDB"))
        #expect(unmanaged(try await manager.addons(in: installation)).isEmpty)
    }
}
