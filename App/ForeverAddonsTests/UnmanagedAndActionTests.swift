import AddonKit
import Foundation
import Testing

@Suite struct UnmanagedRowTests {
    let questie = UnmanagedFolder(
        folder: "Questie", folders: ["Questie", "QuestieDB"],
        toc: Toc(parsing: "## Interface: 16001\n## Title: Questie|cFF00FF00 v12.0.4|r\n"),
        tocFile: "Questie_Camelot.toc", isLoaded: true, supportsFlavor: true,
        candidates: [AdoptionCandidate(ref: AddonRef(source: .github, identifier: "Questie/Questie"), name: "Questie",
                                       reason: "Matched CurseForge project 334372", source: .curseForge)]
    )

    @Test func groupedRowShowsTheLoadedTitleAndFolderCount() {
        let row = InstalledRow(status: .unmanaged(questie), update: nil)
        #expect(row.id == "unmanaged:Questie")
        #expect(row.name == "Questie")
        #expect(row.subtitle == "2 folders")
        #expect(row.version == "v12.0.4")
        #expect(!row.isNotLoaded && row.condition == .unmanaged && !row.isManaged)
    }

    @Test func singleFolderRows() {
        let renamed = InstalledRow(status: .unmanaged(UnmanagedFolder(folder: "QDB", toc: Toc(parsing: "## Title: QuestieDB\n"))), update: nil)
        #expect(renamed.name == "QuestieDB" && renamed.subtitle == "QDB")
        #expect(renamed.isNotLoaded)
        let bare = InstalledRow(status: .unmanaged(UnmanagedFolder(folder: "NoToc")), update: nil)
        #expect(bare.name == "NoToc" && bare.subtitle == nil && bare.version.isEmpty)
    }

    @Test func removalMessagesListEveryFolder() {
        let request = RemovalRequest.unmanaged(questie)
        #expect(request.title == "Move Questie to the Trash?")
        #expect(request.confirmLabel == "Move to Trash")
        #expect(request.message.hasPrefix("Moves Questie, QuestieDB from Interface/AddOns to the Trash."))
        #expect(request.id == "unmanaged:Questie")
        let addon = InstalledAddon(id: AddonRef(source: .github, identifier: "o/A"), name: "A", folders: ["A", "A_Options"],
                                   version: "1", releaseID: 1, assetName: "a.zip", publishedAt: .now, installedAt: .now)
        #expect(RemovalRequest.managed(addon).message == "Removes A, A_Options from Interface/AddOns. Saved settings are kept.")
    }
}

@Suite struct AdoptFormTests {
    let ref = AddonRef(source: .github, identifier: "Questie/Questie")
    var candidates: [AdoptionCandidate] {
        [AdoptionCandidate(ref: ref, name: "Questie", reason: "Matched CurseForge project 334372", source: .curseForge)]
    }

    @Test(arguments: ["Questie/Questie", "github:Questie/Questie", "https://github.com/Questie/Questie.git", " www.github.com/Questie/Questie "])
    func parsesRefs(text: String) {
        #expect(AdoptForm.parse(text) == ref)
    }

    @Test(arguments: ["", "owner/repo/extra", "just words", "owner/re po"])
    func rejectsOtherText(text: String) {
        #expect(AdoptForm.parse(text) == nil)
    }

    @Test func reasons() {
        #expect(AdoptForm.reason(for: "questie/questie", candidates: candidates, searched: []) == "Matched CurseForge project 334372")
        let other = AddonRef(source: .github, identifier: "a/b")
        #expect(AdoptForm.reason(for: "a/b", candidates: candidates, searched: [other]) == "Picked from a GitHub search")
        #expect(AdoptForm.reason(for: "c/d", candidates: candidates, searched: []) == "Entered by hand")
        #expect(AdoptForm.reason(for: "", candidates: candidates, searched: []) == nil)
    }

    @Test func adoptNeedsAValidRefAndNoKnownBlocker() {
        #expect(!AdoptForm.canAdopt(text: "nope", previewed: nil, preview: nil, isBusy: false))
        #expect(AdoptForm.canAdopt(text: "Questie/Questie", previewed: nil, preview: nil, isBusy: false))
        #expect(!AdoptForm.canAdopt(text: "Questie/Questie", previewed: nil, preview: nil, isBusy: true))
        #expect(!AdoptForm.canAdopt(text: "Questie/Questie", previewed: ref, preview: .noBuild, isBusy: false))
        #expect(AdoptForm.canAdopt(text: "Questie/Questie", previewed: ref, preview: .loading, isBusy: false))
        // A blocker found for another repo doesn't block this one.
        #expect(AdoptForm.canAdopt(text: "Other/Repo", previewed: ref, preview: .noBuild, isBusy: false))

        let release = ResolvedRelease(ref: ref, name: "Questie", version: "v12.0.4", releaseID: 1, publishedAt: .now,
                                      downloadURL: URL(string: "https://x")!, assetName: "q.zip")
        let conflict = AdoptionPreview(release: release, folders: ["Questie"], replaces: [], adds: [],
                                       conflicts: ["Questie": AddonRef(source: .github, identifier: "x/Questie")])
        #expect(!AdoptForm.canAdopt(text: "Questie/Questie", previewed: ref, preview: .ready(conflict), isBusy: false))
        let clean = AdoptionPreview(release: release, folders: ["Questie", "QuestieDB"], replaces: ["Questie", "QuestieDB"], adds: [])
        #expect(AdoptForm.canAdopt(text: "Questie/Questie", previewed: ref, preview: .ready(clean), isBusy: false))
    }

    @Test func searchUsesTheTitleWhenTheFieldIsARef() {
        #expect(AdoptForm.searchText(field: "Questie/Questie", title: "Questie") == "Questie")
        #expect(AdoptForm.searchText(field: " ", title: "Questie") == "Questie")
        #expect(AdoptForm.searchText(field: "questie classic", title: "Questie") == "questie classic")
    }
}

@Suite struct BrowseLabelTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    let locale = Locale(identifier: "en_US")

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func label(_ date: Date?, now: Date) -> String {
        FetchLabel.string(for: date, now: now, calendar: calendar, locale: locale).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func lastFetched() {
        let now = date(2026, 10, 13, 9, 0)
        #expect(label(nil, now: now) == "Not fetched yet")
        #expect(label(date(2026, 10, 13, 7, 18), now: now) == "Last fetched Today, 7:18 AM")
        #expect(label(date(2026, 10, 12, 7, 18), now: now) == "Last fetched Oct 12, 7:18 AM")
        #expect(label(date(2025, 12, 30, 19, 5), now: now) == "Last fetched Dec 30, 2025, 7:05 PM")
    }

    @Test func notCheckedIsNeutralAndDistinctFromNoReleaseJSON() {
        #expect(SupportLabel.text(for: .unknown, flavor: .forever) == "Not checked")
        #expect(SupportLabel.help(for: .unknown, flavor: .forever) == "Open this add-on to check Forever support")
        #expect(SupportLabel.text(for: .needsDownload, flavor: .forever) == "Unknown, no release.json")
        #expect(SupportLabel.help(for: .needsDownload, flavor: .forever).contains("only be confirmed by installing"))
    }
}

/// Browse rows and the inspector ask the same model question, so they agree, including when a
/// search result's repo name differs in case from the installed record.
@MainActor @Suite struct InstallActionTests {
    let root: URL
    let manager: AddonManager
    let installation: Installation

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "InstallActionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let game = root.appending(path: "World of Warcraft/_classic_beta_", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: game.appending(path: "Interface/AddOns"), withIntermediateDirectories: true)
        manager = AddonManager(
            directories: AppDirectories(root: root.appending(path: "AppData")),
            locator: InstallationLocator(baseFolders: [], findApps: { [] }),
            keychain: KeychainStore(service: "ForeverAddonsTests-\(UUID().uuidString)"),
            environment: [:]
        )
        installation = try await manager.addInstallation(at: game)
    }

    func addon(_ identifier: String, version: String) -> InstalledAddon {
        InstalledAddon(id: AddonRef(source: .github, identifier: identifier), name: String(identifier.split(separator: "/")[1]),
                       folders: [String(identifier.split(separator: "/")[1])], version: version, releaseID: 1,
                       assetName: "a.zip", publishedAt: .now, installedAt: .now)
    }

    func result(_ identifier: String) -> SearchResult {
        SearchResult(id: AddonRef(source: .github, identifier: identifier), name: identifier, owner: "o", origin: [.catalogue])
    }

    @Test func rowAndInspectorAgree() async throws {
        let bags = addon("Cidan/BetterBags", version: "v0.5.14")
        let bugSack = addon("funkydude/BugSack", version: "v1")
        try await manager.store.modify(installation) { $0 = [bags, bugSack] }
        let model = InstallationModel(installation: installation, manager: manager, reportError: { _ in })
        await model.reload()
        let release = ResolvedRelease(ref: bugSack.id, name: "BugSack", version: "v2", releaseID: 2, publishedAt: .now,
                                      downloadURL: URL(string: "https://x")!, assetName: "b.zip")
        model.apply([bugSack.id: .available(release), bags.id: .upToDate])

        let cases: [(String, InstallAction)] = [
            ("cidan/betterbags", .installed(ref: bags.id, version: "v0.5.14")),
            ("funkydude/BugSack", .update(ref: bugSack.id, version: "v1", available: "v2")),
            ("someone/NotInstalled", .install),
        ]
        for (identifier, expected) in cases {
            let ref = AddonRef(source: .github, identifier: identifier)
            let inspector = model.installAction(for: ref)
            let row = model.browseRow(for: result(identifier))
            #expect(inspector == expected, "\(identifier)")
            #expect(row.action == inspector, "\(identifier)")
            #expect(row.isInstalled == (expected != .install))
        }
        // A pinned add-on with an update shows as installed, not as an update.
        var pinned = bugSack
        pinned.pinned = true
        #expect(InstallAction(installed: pinned, update: .available(release)) == .installed(ref: bugSack.id, version: "v1"))
    }
}
