import AddonKit
import Foundation

/// Fixed data for `SnapshotTests`. Test target only: the app itself uses real data only
/// (decision 0007), so nothing here may move into `App/Reload`.
nonisolated enum Fixtures {
    static let installation = Installation(
        id: "snapshot-forever",
        root: URL(filePath: "/tmp/ReloadSnapshots/World of Warcraft/_classic_beta_", directoryHint: .isDirectory),
        flavor: .forever, gameVersion: "1.60.1.70338")

    static func date(_ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    static func ref(_ identifier: String) -> AddonRef { AddonRef(source: .github, identifier: identifier) }

    static func addon(
        _ identifier: String, _ name: String, version: String, folders: [String]? = nil, pinned: Bool = false,
        installed: Date = date(9, 28), retailBuild: Bool = false
    ) -> InstalledAddon {
        InstalledAddon(
            id: ref(identifier), name: name, folders: folders ?? [name], version: version, releaseID: 1,
            assetName: "\(name).zip", publishedAt: date(9, 20), installedAt: installed, pinned: pinned,
            changelog: installedChangelog, installedFlavorBuild: retailBuild ? .mainline : nil)
    }

    static func release(_ identifier: String, _ name: String, version: String, flavorBuild: Flavor? = nil) -> ResolvedRelease {
        ResolvedRelease(ref: ref(identifier), name: name, version: version, releaseID: 2, publishedAt: date(10, 8),
                        downloadURL: URL(string: "https://example.invalid/\(name).zip")!, assetName: "\(name).zip",
                        changelog: releaseChangelog, flavorBuild: flavorBuild)
    }

    // MARK: Installed

    static let betterBags = addon("Cidan/BetterBags", "BetterBags", version: "v0.5.14")
    static let bugSack = addon("funkydude/BugSack", "BugSack", version: "v11.2.0", folders: ["BugSack", "!BugGrabber"])
    static let pinnedDBM = addon("DeadlyBossMods/DeadlyBossMods", "Deadly Boss Mods", version: "11.2.15", folders: ["DBM-Core", "DBM-GUI"], pinned: true)
    static let retailOnlyInstalled = addon("Tercioo/Details-Damage-Meter", "Details!", version: "#Details.20250930", retailBuild: true)
    static let littleWigs = addon("BigWigsMods/LittleWigs", "LittleWigs", version: "v11.2.6")

    static let questie = UnmanagedFolder(
        folder: "Questie", folders: ["Questie", "QuestieDB"],
        toc: Toc(parsing: "## Interface: 16001\n## Title: Questie|cFF00FF00 v12.0.4|r\n## Author: Aero, Logon\n## Notes: Quest helper with map pins and tracker\n"),
        tocFile: "Questie_Camelot.toc", isLoaded: true, supportsFlavor: true,
        candidates: [
            AdoptionCandidate(ref: ref("Questie/Questie"), name: "Questie", reason: "Matched CurseForge project 334372", source: .curseForge),
            AdoptionCandidate(ref: ref("Questie/QuestieDB"), name: "QuestieDB", reason: "Catalogue name matches the TOC title", source: .catalogueName),
        ])
    static let notLoaded = UnmanagedFolder(folder: "OldMinimap", toc: Toc(parsing: "## Interface: 110200\n## Title: Old Minimap\n## Version: 3.1\n"),
                                           tocFile: "OldMinimap.toc")

    static let addons: [AddonStatus] = [
        .managed(betterBags, missingFolders: []),
        .managed(bugSack, missingFolders: []),
        .managed(pinnedDBM, missingFolders: []),
        .managed(retailOnlyInstalled, missingFolders: []),
        .managed(littleWigs, missingFolders: []),
        .unmanaged(questie),
        .unmanaged(notLoaded),
    ]

    static let updates: [AddonRef: UpdateState] = [
        betterBags.id: .upToDate,
        bugSack.id: .available(release("funkydude/BugSack", "BugSack", version: "v11.2.3")),
        pinnedDBM.id: .pinned,
        retailOnlyInstalled.id: .available(release("Tercioo/Details-Damage-Meter", "Details!", version: "#Details.20250930")),
        littleWigs.id: .upToDate,
    ]

    // MARK: Dependencies

    static let bigWigs = DependencyCandidate(ref: ref("BigWigsMods/BigWigs"), name: "BigWigs",
                                             reason: "Its latest release ships the BigWigs folder")
    /// LittleWigs needs BigWigs, which isn't installed; the core is sure which add-on provides it.
    static let missingDependencies = [
        MissingDependency(folder: "BigWigs", requiredBy: [littleWigs.id], candidates: [bigWigs], suggested: bigWigs),
    ]
    /// Every kind the Requires section shows: a suggestion, several candidates, and none.
    static let missingDependencyKinds = missingDependencies + [
        MissingDependency(folder: "LibSharedMedia-3.0", requiredBy: [littleWigs.id], candidates: [
            DependencyCandidate(ref: ref("example/LibSharedMedia"), name: "LibSharedMedia-3.0", reason: "Its latest release ships the folder"),
            DependencyCandidate(ref: ref("example/SharedMedia"), name: "SharedMedia", reason: "WoWInterface lists the folder"),
        ]),
        MissingDependency(folder: "LittleWigs_Extras", requiredBy: [littleWigs.id]),
    ]

    // MARK: Browse

    static func result(
        _ identifier: String, _ name: String, summary: String?, stars: Int, updated: Date,
        flavors: Set<Flavor>?, support: SupportStatus = .unknown
    ) -> SearchResult {
        SearchResult(id: ref(identifier), name: name, summary: summary, owner: String(identifier.split(separator: "/")[0]),
                     stars: stars, lastUpdated: updated, support: support, availableFlavors: flavors, origin: [.catalogue])
    }

    static let browseInstalled = result("Cidan/BetterBags", "BetterBags", summary: "A bag replacement with categories and search",
                                        stars: 412, updated: date(10, 2), flavors: [.forever, .mainline], support: .supported(version: "v0.5.14"))
    static let browseUpdate = result("funkydude/BugSack", "BugSack", summary: "Collects Lua errors in a sack you can open later",
                                     stars: 88, updated: date(10, 8), flavors: [.forever, .mainline, .vanilla], support: .supported(version: "v11.2.3"))
    static let browseNotInstalled = result("WeakAuras/WeakAuras2", "WeakAuras", summary: "Custom auras, bars and icons driven by triggers",
                                           stars: 1350, updated: date(10, 10), flavors: [.forever, .mainline, .vanilla, .mists], support: .supported(version: "5.20.1"))
    static let browseRetailOnly = result("Tercioo/Plater-Nameplates", "Plater", summary: "Nameplate add-on with scripting and animations",
                                         stars: 220, updated: date(9, 30), flavors: [.mainline], support: .unsupported)
    static let browseClassicOnly = result("Questie/Questie", "Questie", summary: "Quest objectives on the map for classic flavors",
                                          stars: 960, updated: date(10, 5), flavors: [.vanilla, .tbc, .wrath], support: .unsupported)
    static let browseUnchecked = result("someone/TinyTooltip", "TinyTooltip", summary: nil,
                                        stars: 31, updated: date(8, 14), flavors: nil, support: .needsDownload)

    static let browseResults = [browseInstalled, browseUpdate, browseNotInstalled, browseRetailOnly, browseClassicOnly, browseUnchecked]

    static let browseContent = BrowseContent(popular: browseResults, recent: browseResults.reversed())

    // MARK: Details

    static func readme(_ name: String) -> String {
        """
        # \(name)

        \(name) keeps its settings **per character** and works with the default UI.

        - Open the options with `/\(name.lowercased())`
        - Drag the frame to move it
        """
    }

    static let installedChangelog = "- Fixed bag sorting on login\n- Faster search"
    static let releaseChangelog = "- New: category filters\n- Fixed a taint warning"
    static let latestChangelog = "- New: category filters"
    /// Release notes the inspector snapshots show, for warming `MarkdownCache`.
    static let markdownShown = [installedChangelog, releaseChangelog, latestChangelog]

    static func details(for result: SearchResult, latest: String?) -> AddonDetails {
        AddonDetails(
            ref: result.id, name: result.name, owner: result.owner, summary: result.summary,
            repositoryURL: URL(string: "https://github.com/\(result.id.identifier)")!, stars: result.stars,
            lastUpdated: result.lastUpdated, topics: ["wow", "addon"], license: "MIT", readme: readme(result.name),
            latestVersion: latest, latestPublishedAt: date(10, 8), latestChangelog: latestChangelog,
            support: result.support, availableFlavors: result.availableFlavors)
    }

    static let lastRefresh = date(10, 11, 7, 18)

    static let gitHubStatusNow = date(10, 12, 9, 7)
    /// API calls partly spent, search used up, github.com paused after a 429.
    static let gitHubStatus = GitHubStatus(
        api: RateLimitState(remaining: 42, resetAt: date(10, 12, 9, 30)),
        search: RateLimitState(remaining: 0, resetAt: gitHubStatusNow.addingTimeInterval(40)),
        apiLimit: 60, hasToken: false,
        webPausedUntil: date(10, 12, 9, 11)
    )
}

/// A test-only `AddonManaging` that serves `Fixtures` and does nothing else: no disk, no
/// network. Actions that would change something throw or finish at once.
nonisolated struct FixtureManager: AddonManaging {
    struct Unsupported: Error {}

    var addonList: [AddonStatus] = Fixtures.addons
    var content = Fixtures.browseContent
    var missing: [MissingDependency] = Fixtures.missingDependencies
    /// What `dependents(of:in:)` reports, by ref.
    var dependentsByRef: [AddonRef: [InstalledAddon]] = [:]
    /// Refs `install` succeeds for, with the record it returns; the rest throw.
    var installable: [AddonRef: InstalledAddon] = [:]

    func installations() async throws -> [Installation] { [Fixtures.installation] }
    func detectInstallations() async throws -> [Installation] { [Fixtures.installation] }
    func addInstallation(at url: URL) async throws -> Installation { throw Unsupported() }
    func addons(in installation: Installation) async throws -> [AddonStatus] { addonList }
    func search(_ query: SearchQuery, in installation: Installation) -> AsyncStream<[SearchResult]> { Self.finished() }
    func browse(in installation: Installation) async -> BrowseContent { content }
    func resolve(_ ref: AddonRef, for installation: Installation, channel: Channel) async throws -> ResolvedRelease { throw Unsupported() }
    func install(
        _ ref: AddonRef, into installation: Installation, channel: Channel, force: Bool, allowFamilyFallback: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledAddon {
        guard let addon = installable[ref] else { throw Unsupported() }
        return addon
    }
    func checkForUpdates(in installation: Installation) async throws -> [AddonRef: UpdateState] { Fixtures.updates }
    func update(_ refs: [AddonRef], in installation: Installation) -> AsyncStream<OperationEvent> { Self.finished() }
    func update(releases: [ResolvedRelease], in installation: Installation) -> AsyncStream<OperationEvent> { Self.finished() }
    func uninstall(_ ref: AddonRef, from installation: Installation) async throws {}
    func rollback(_ ref: AddonRef, in installation: Installation) async throws {}
    func setPinned(_ pinned: Bool, for ref: AddonRef, in installation: Installation) async throws {}
    func setChannel(_ channel: Channel, for ref: AddonRef, in installation: Installation) async throws {}
    func adopt(folder: String, as ref: AddonRef, in installation: Installation) async throws -> InstalledAddon { throw Unsupported() }
    func adopt(_ release: ResolvedRelease, in installation: Installation) async throws -> InstalledAddon { throw Unsupported() }
    func adoptionCandidates(folder: String, in installation: Installation) async -> [AdoptionCandidate] { [] }
    func adoptionPreview(for ref: AddonRef, folders: [String], in installation: Installation) async throws -> AdoptionPreview {
        AdoptionPreview(release: Fixtures.release(ref.identifier, ref.identifier, version: "v12.0.4"), folders: folders,
                        replaces: folders, adds: ["QuestieLearner"])
    }
    func removeUnmanaged(folders: [String], from installation: Installation) async throws -> [String] { [] }
    func tokenDidChange() async {}
    func gitHubStatus() async -> GitHubStatus { Fixtures.gitHubStatus }
    func details(for ref: AddonRef, in installation: Installation) async throws -> AddonDetails { throw Unsupported() }
    func releaseNotes(for ref: AddonRef, in installation: Installation) async throws -> (version: String, publishedAt: Date?, markdown: String)? { nil }
    func refresh(in installation: Installation, force: Bool) -> AsyncStream<RefreshProgress> { Self.finished() }
    func lastRefresh(in installation: Installation) async -> Date? { Fixtures.lastRefresh }
    func metadataChanges() -> AsyncStream<MetadataChange> { Self.finished() }
    func metadataVersion() async -> Int64? { nil }
    var storeDirectory: URL { URL(filePath: "/tmp/ReloadSnapshots/store", directoryHint: .isDirectory) }
    func storedAvailability(for refs: [AddonRef], in installation: Installation) async -> [AddonRef: StoredAvailability] { [:] }
    func missingDependencies(in installation: Installation) async -> [MissingDependency] { missing }
    func missingDependencies(of ref: AddonRef, in installation: Installation) async -> [MissingDependency] {
        missing.filter { $0.requiredBy.contains(ref) }
    }
    func dependents(of ref: AddonRef, in installation: Installation) async -> [InstalledAddon] { dependentsByRef[ref] ?? [] }

    private static func finished<T>() -> AsyncStream<T> {
        AsyncStream { $0.finish() }
    }
}
