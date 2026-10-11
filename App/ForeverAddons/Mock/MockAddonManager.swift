import AddonKit
import Foundation

/// In-memory `AddonManaging` with realistic sample data. Used for SwiftUI previews and,
/// until the real `AddonManager` lands, for running the app.
///
/// Behaviour worth knowing when clicking around:
/// - BigWigs and Details! have updates; Details!'s first update attempt fails (to exercise
///   per-row errors in Update All), a retry succeeds.
/// - BugSack is pinned. Leatrix_Plus is an unmanaged folder that can be adopted.
/// - Search emits immediately with `.checking` badges, then resolves support over ~1 s.
/// - Installing an add-on verified as unsupported throws `noCompatibleRelease`.
actor MockAddonManager: AddonManaging {
    struct CatalogueItem: Sendable {
        var ref: AddonRef
        var name: String
        var summary: String
        var stars: Int
        var updatedDaysAgo: Double
        var support: SupportStatus
        var keywords: [String]
        var folders: [String]
        var version: String
        var origin: SearchOrigin = .catalogue
    }

    private struct InstallationData {
        var installation: Installation
        var managed: [AddonRef: InstalledAddon] = [:]
        var missingFolders: [AddonRef: [String]] = [:]
        var unmanaged: [(folder: String, toc: Toc?, suggested: AddonRef?)] = []
        var available: [AddonRef: ResolvedRelease] = [:]
        var previous: [AddonRef: InstalledAddon] = [:]
    }

    private var data: [Installation.ID: InstallationData] = [:]
    private var order: [Installation.ID] = []
    private var supportCache: [AddonRef: SupportStatus] = [:]
    private var failuresRemaining: Set<AddonRef> = []
    private var nextReleaseID: Int64 = 900_000
    /// Multiplies every simulated delay. 0 makes the mock instant (handy for previews).
    private let latency: Double

    init(latency: Double = 1) {
        self.latency = latency
        let installation = Self.foreverBeta
        var beta = InstallationData(installation: installation)
        for addon in Self.sampleInstalled { beta.managed[addon.id] = addon }
        beta.unmanaged = [(
            folder: "Leatrix_Plus",
            toc: Toc(parsing: """
                ## Interface: 16001, 11507
                ## Title: |cffffd800Leatrix Plus|r
                ## Version: 1.60.08-forever
                ## Notes: Lots of small quality of life tweaks.
                ## Author: Leatrix
                """),
            suggested: AddonRef(source: .github, identifier: "leatrix/LeatrixPlus")
        )]
        beta.available[Self.bigWigs] = Self.release(
            for: Self.bigWigs, name: "BigWigs", version: "v426.4", id: 426_004, daysAgo: 1,
            changelog: """
                ## v426.4

                - **Forever:** Added timers for *Molten Core* trash packs.
                - Fixed Ragnaros submerge bar drifting by ~2 s.
                - Updated `BigWigs_Plugins` to support the new nameplate API.

                See [the full changelog](https://github.com/BigWigsMods/BigWigs/releases).
                """)
        beta.available[Self.details] = Self.release(
            for: Self.details, name: "Details! Damage Meter", version: "Details.20261009.14021",
            id: 140_210, daysAgo: 2,
            changelog: "- Fixed overall data not resetting on Forever.\n- New *Death Recap* plugin layout.")
        beta.previous[Self.bigWigs] = InstalledAddon(
            id: Self.bigWigs, name: "BigWigs", folders: Self.sampleInstalled[0].folders, version: "v426.2",
            releaseID: 426_002, assetName: "BigWigs-v426.2.zip", publishedAt: .daysAgo(20),
            installedAt: .daysAgo(19))
        data[installation.id] = beta
        order = [installation.id]
        failuresRemaining = [Self.details]
    }

    // MARK: Sample data

    static let bigWigs = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs")
    static let dbm = AddonRef(source: .github, identifier: "DeadlyBossMods/DeadlyBossMods")
    static let bugSack = AddonRef(source: .github, identifier: "funkydude/BugSack")
    static let details = AddonRef(source: .github, identifier: "Tercioo/Details-Damage-Meter")

    static let foreverBeta = Installation(
        id: "forever-beta",
        root: URL(filePath: "/Applications/World of Warcraft/_classic_beta_", directoryHint: .isDirectory),
        flavor: .forever, productCode: "wow_classic_beta", gameVersion: "1.60.1.70338")

    static let sampleInstalled: [InstalledAddon] = [
        InstalledAddon(
            id: bigWigs, name: "BigWigs",
            folders: ["BigWigs", "BigWigs_Core", "BigWigs_Plugins", "BigWigs_Options"],
            version: "v426.3", releaseID: 426_003, assetName: "BigWigs-v426.3.zip",
            publishedAt: .daysAgo(9), installedAt: .daysAgo(8)),
        InstalledAddon(
            id: dbm, name: "DBM - Core", folders: ["DBM-Core", "DBM-GUI", "DBM-StatusBarTimers"],
            version: "12.1.12", releaseID: 121_12, assetName: "DBM-Core-12.1.12.zip",
            publishedAt: .daysAgo(3), installedAt: .daysAgo(3)),
        InstalledAddon(
            id: bugSack, name: "BugSack", folders: ["BugSack"], version: "v11.2.5", releaseID: 112_5,
            assetName: "BugSack-v11.2.5.zip", publishedAt: .daysAgo(60), installedAt: .daysAgo(40),
            pinned: true),
        InstalledAddon(
            id: details, name: "Details! Damage Meter", folders: ["Details", "Details_DataStorage"],
            version: "Details.20260921.13950", releaseID: 139_500, assetName: "Details-20260921.zip",
            publishedAt: .daysAgo(20), installedAt: .daysAgo(18), channel: .prerelease),
    ]

    static let catalogue: [CatalogueItem] = [
        .init(ref: .gh("BigWigsMods/BigWigs"), name: "BigWigs", summary: "Modular, lightweight, non-intrusive approach to boss encounter warnings.",
              stars: 690, updatedDaysAgo: 1, support: .supported(version: "v426.4"), keywords: ["boss", "raid", "timers", "bw"], folders: ["BigWigs"], version: "v426.4"),
        .init(ref: .gh("DeadlyBossMods/DeadlyBossMods"), name: "Deadly Boss Mods", summary: "Raid and dungeon encounter alerts and timers.",
              stars: 520, updatedDaysAgo: 3, support: .supported(version: "12.1.12"), keywords: ["boss", "raid", "dbm", "timers"], folders: ["DBM-Core"], version: "12.1.12"),
        .init(ref: .gh("plusmouse/Baganator"), name: "Baganator", summary: "Single or category bag views with search across characters.",
              stars: 260, updatedDaysAgo: 2, support: .supported(version: "v720"), keywords: ["bags", "inventory", "bank"], folders: ["Baganator"], version: "v720"),
        .init(ref: .gh("Cidan/BetterBags"), name: "BetterBags", summary: "A bag replacement with categories and sections.",
              stars: 410, updatedDaysAgo: 2, support: .supported(version: "v0.3.12"), keywords: ["bags", "inventory"], folders: ["BetterBags"], version: "v0.3.12"),
        .init(ref: .gh("Jaliborc/Bagnon"), name: "Bagnon", summary: "Single-window displays for your inventory, bank and void storage.",
              stars: 300, updatedDaysAgo: 5, support: .needsDownload, keywords: ["bags", "inventory", "bank"], folders: ["Bagnon"], version: "10.2.6"),
        .init(ref: .gh("AdiAddons/AdiBags"), name: "AdiBags", summary: "Displays bag contents in one window, smartly filtered into sections.",
              stars: 180, updatedDaysAgo: 34, support: .unknown, keywords: ["bags", "inventory"], folders: ["AdiBags"], version: "v1.10.29"),
        .init(ref: .gh("Questie/Questie"), name: "Questie", summary: "The ultimate Classic quest helper.",
              stars: 980, updatedDaysAgo: 4, support: .unsupported, keywords: ["quests", "maps", "helper"], folders: ["Questie"], version: "v10.4.1"),
        .init(ref: .gh("Auctionator/Auctionator"), name: "Auctionator", summary: "Faster auction house scanning, shopping lists and selling.",
              stars: 340, updatedDaysAgo: 6, support: .supported(version: "10.4.8"), keywords: ["auction", "ah", "gold"], folders: ["Auctionator"], version: "10.4.8"),
        .init(ref: .gh("tullamods/OmniCC"), name: "OmniCC", summary: "Cooldown count for everything.",
              stars: 210, updatedDaysAgo: 12, support: .supported(version: "11.0.3"), keywords: ["combat", "cooldowns", "ui"], folders: ["OmniCC"], version: "11.0.3"),
        .init(ref: .gh("Tercioo/Plater-Nameplates"), name: "Plater Nameplates", summary: "Highly customizable nameplates with scripting.",
              stars: 450, updatedDaysAgo: 8, support: .supported(version: "Plater-v612"), keywords: ["ui", "nameplates", "combat"], folders: ["Plater"], version: "Plater-v612"),
        .init(ref: .gh("Tercioo/Details-Damage-Meter"), name: "Details! Damage Meter", summary: "Damage, heal and threat meter with plugins.",
              stars: 610, updatedDaysAgo: 2, support: .supported(version: "Details.20261009.14021"), keywords: ["combat", "meter", "damage", "dps"], folders: ["Details"], version: "Details.20261009.14021"),
        .init(ref: .gh("Nevcairiel/HandyNotes"), name: "HandyNotes", summary: "Handy notes for your maps.",
              stars: 90, updatedDaysAgo: 120, support: .noReleases, keywords: ["maps", "notes"], folders: ["HandyNotes"], version: "v1.6.24"),
        .init(ref: .gh("Jaliborc/TomTom"), name: "TomTom", summary: "Waypoint arrow and coordinate display.",
              stars: 70, updatedDaysAgo: 45, support: .unsupported, keywords: ["maps", "waypoints", "quests"], folders: ["TomTom"], version: "v4.0.5"),
        .init(ref: .gh("tukui-org/ElvUI-Camelot"), name: "ElvUI Camelot", summary: "A full user interface replacement for Forever.",
              stars: 140, updatedDaysAgo: 3, support: .supported(version: "13.92"), keywords: ["ui", "unitframes", "actionbars"], folders: ["ElvUI"], version: "13.92"),
    ]

    /// Extra results that only appear when `includeLiveGitHub` is set.
    static let liveGitHub: [CatalogueItem] = [
        .init(ref: .gh("someone/ForeverBagSort"), name: "ForeverBagSort", summary: "Tiny bag sorting add-on made for Forever.",
              stars: 12, updatedDaysAgo: 9, support: .needsDownload, keywords: ["bags", "sort"], folders: ["ForeverBagSort"], version: "0.4.0", origin: .github),
        .init(ref: .gh("raidtools/CamelotTimers"), name: "CamelotTimers", summary: "Boss timers for Forever raids.",
              stars: 31, updatedDaysAgo: 15, support: .supported(version: "1.2.0"), keywords: ["boss", "raid", "timers"], folders: ["CamelotTimers"], version: "1.2.0", origin: .github),
        .init(ref: .gh("minimal/MiniUI"), name: "MiniUI", summary: "Minimal UI tweaks.",
              stars: 8, updatedDaysAgo: 200, support: .noReleases, keywords: ["ui"], folders: ["MiniUI"], version: "0.1", origin: .github),
    ]

    static func release(for ref: AddonRef, name: String, version: String, id: Int64, daysAgo: Double, changelog: String?) -> ResolvedRelease {
        let asset = "\(name.filter { !$0.isWhitespace && $0 != "!" })-\(version).zip"
        return ResolvedRelease(
            ref: ref, name: name, version: version, releaseID: id, publishedAt: .daysAgo(daysAgo),
            downloadURL: URL(string: "https://github.com/\(ref.identifier)/releases/download/\(version)/\(asset)")!,
            assetName: asset, changelog: changelog,
            reasoning: ["release.json lists flavor \"forever\" (interface 16001)", "picked \(asset)"])
    }

    // MARK: Helpers

    private func pause(_ seconds: Double) async {
        guard latency > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds * latency))
    }

    private func entry(_ installation: Installation) throws -> InstallationData {
        guard let entry = data[installation.id] else { throw AddonError.installationNotFound(installation.id) }
        return entry
    }

    private static func item(for ref: AddonRef) -> CatalogueItem? {
        (catalogue + liveGitHub).first { $0.ref == ref }
    }

    // MARK: AddonManaging

    func installations() async throws -> [Installation] {
        await pause(0.2)
        return order.compactMap { data[$0]?.installation }
    }

    func addInstallation(at url: URL) async throws -> Installation {
        await pause(0.3)
        let folder = url.lastPathComponent
        let flavor = Flavor.allCases.first { $0.rules.knownSubfolders[folder] != nil } ?? .forever
        let installation = Installation(
            id: "mock-\(abs(url.standardizedFileURL.path.hashValue))", root: url, flavor: flavor,
            productCode: flavor.rules.knownSubfolders[folder], gameVersion: nil)
        if data[installation.id] == nil {
            data[installation.id] = InstallationData(installation: installation)
            order.append(installation.id)
        }
        return installation
    }

    func addons(in installation: Installation) async throws -> [AddonStatus] {
        await pause(0.3)
        let entry = try entry(installation)
        let managed = entry.managed.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { AddonStatus.managed($0, missingFolders: entry.missingFolders[$0.id] ?? []) }
        let unmanaged = entry.unmanaged.map { AddonStatus.unmanaged(folder: $0.folder, toc: $0.toc, suggestedRef: $0.suggested) }
        return managed + unmanaged
    }

    nonisolated func search(_ query: SearchQuery, in installation: Installation) -> AsyncStream<[SearchResult]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SearchResult].self, bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            await self.runSearch(query, in: installation, continuation: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runSearch(_ query: SearchQuery, in installation: Installation, continuation: AsyncStream<[SearchResult]>.Continuation) async {
        let managed = data[installation.id]?.managed ?? [:]
        let words = query.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)

        func matches(_ item: CatalogueItem) -> Bool {
            guard !words.isEmpty else { return true }
            let haystack = ([item.name, item.ref.identifier, item.summary] + item.keywords).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }

        var items = Self.catalogue.filter(matches)
        // Direct `owner/repo` reference that no layer knows about.
        let trimmed = query.text.trimmingCharacters(in: .whitespaces)
        if trimmed.split(separator: "/").count == 2, !trimmed.contains(" "),
           !items.contains(where: { $0.ref.identifier.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            let repo = String(trimmed.split(separator: "/")[1])
            items = [CatalogueItem(ref: .gh(trimmed), name: repo, summary: "Install directly from github.com/\(trimmed)",
                                   stars: 0, updatedDaysAgo: 0, support: .needsDownload, keywords: [], folders: [repo],
                                   version: "1.0.0", origin: .direct)]
        }

        var support: [AddonRef: SupportStatus] = [:]
        for item in items {
            if let installed = managed[item.ref] { support[item.ref] = .supported(version: installed.version) }
            else { support[item.ref] = supportCache[item.ref] ?? .checking }
        }

        func emit() {
            let results = items.compactMap { item -> SearchResult? in
                let status = support[item.ref] ?? .unknown
                if query.foreverOnly, status == .unsupported { return nil }
                let installed = managed[item.ref]
                var origin: Set<SearchOrigin> = [item.origin]
                if installed != nil { origin.insert(.installed) }
                return SearchResult(
                    id: item.ref, name: item.name, summary: item.summary,
                    owner: String(item.ref.identifier.split(separator: "/").first ?? ""),
                    stars: item.origin == .direct ? nil : item.stars,
                    lastUpdated: item.origin == .direct ? nil : .daysAgo(item.updatedDaysAgo),
                    installed: installed, support: status, origin: origin)
            }
            continuation.yield(results)
        }

        emit()

        if query.includeLiveGitHub {
            await pause(0.6)
            guard !Task.isCancelled else { return }
            let live = Self.liveGitHub.filter(matches).filter { item in !items.contains { $0.ref == item.ref } }
            for item in live { support[item.ref] = supportCache[item.ref] ?? .checking }
            items += live
            emit()
        }

        // Simulated verification: at most ~15 rows, a few at a time, over about a second.
        let pending = items.filter { support[$0.ref] == .checking }.prefix(15)
        for batch in Array(pending).chunked(into: 2) {
            await pause(Double.random(in: 0.15...0.3))
            guard !Task.isCancelled else { return }
            for item in batch {
                supportCache[item.ref] = item.support
                support[item.ref] = item.support
            }
            emit()
        }
    }

    func resolve(_ ref: AddonRef, for installation: Installation, channel: Channel) async throws -> ResolvedRelease {
        await pause(0.4)
        let entry = try entry(installation)
        if let available = entry.available[ref] { return available }
        if let installed = entry.managed[ref] {
            var release = Self.release(for: ref, name: installed.name, version: installed.version, id: installed.releaseID,
                                       daysAgo: 0, changelog: "## \(installed.version)\n\n- Maintenance release.\n- Updated TOC for Forever `16001`.")
            release.publishedAt = installed.publishedAt
            return release
        }
        guard let item = Self.item(for: ref) else { throw AddonError.notFound(ref) }
        switch item.support {
        case .unsupported, .noReleases: throw AddonError.noCompatibleRelease(ref, installation.flavor)
        default:
            return Self.release(for: ref, name: item.name, version: item.version, id: Int64(abs(ref.identifier.hashValue % 1_000_000)),
                                daysAgo: item.updatedDaysAgo, changelog: "## \(item.version)\n\n\(item.summary)")
        }
    }

    @discardableResult
    func install(_ ref: AddonRef, into installation: Installation, channel: Channel, force: Bool) async throws -> InstalledAddon {
        var entry = try entry(installation)
        await pause(1.2)
        if let item = Self.item(for: ref), item.support == .unsupported || item.support == .noReleases {
            throw AddonError.noCompatibleRelease(ref, installation.flavor)
        }
        let item = Self.item(for: ref)
        let repo = String(ref.identifier.split(separator: "/").last ?? "")
        let folders = item?.folders ?? [repo]
        for folder in folders {
            if let owner = entry.managed.values.first(where: { $0.id != ref && $0.folders.contains(folder) }) {
                throw AddonError.folderConflict(folder: folder, owner: owner.id)
            }
            if !force, entry.unmanaged.contains(where: { $0.folder == folder }) {
                throw AddonError.unmanagedFolderExists(folder)
            }
        }
        nextReleaseID += 1
        let version = item?.version ?? "1.0.0"
        let addon = InstalledAddon(
            id: ref, name: item?.name ?? repo, folders: folders, version: version, releaseID: nextReleaseID,
            assetName: "\(repo)-\(version).zip", publishedAt: .daysAgo(item?.updatedDaysAgo ?? 0), installedAt: .now,
            channel: channel)
        entry.unmanaged.removeAll { folders.contains($0.folder) }
        entry.managed[ref] = addon
        data[installation.id] = entry
        return addon
    }

    func checkForUpdates(in installation: Installation) async throws -> [AddonRef: UpdateState] {
        await pause(0.9)
        let entry = try entry(installation)
        var states: [AddonRef: UpdateState] = [:]
        for addon in entry.managed.values {
            if addon.pinned { states[addon.id] = .pinned }
            else if let release = entry.available[addon.id] { states[addon.id] = .available(release) }
            else { states[addon.id] = .upToDate }
        }
        return states
    }

    nonisolated func update(_ refs: [AddonRef], in installation: Installation) -> AsyncStream<OperationEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: OperationEvent.self)
        let task = Task {
            for ref in refs { continuation.yield(.queued(ref)) }
            for ref in refs {
                guard !Task.isCancelled else { break }
                continuation.yield(await self.performUpdate(ref, in: installation, progress: { continuation.yield($0) }))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func performUpdate(_ ref: AddonRef, in installation: Installation, progress: @Sendable (OperationEvent) -> Void) async -> OperationEvent {
        guard var entry = data[installation.id] else { return .failed(ref, AddonError.installationNotFound(installation.id).localizedDescription) }
        guard let current = entry.managed[ref] else { return .failed(ref, AddonError.notInstalled(ref).localizedDescription) }
        guard let release = entry.available[ref] else { return .done(current) }
        let willFail = failuresRemaining.contains(ref)
        for step in 0...10 {
            if willFail && step == 4 {
                failuresRemaining.remove(ref)
                return .failed(ref, AddonError.http(status: 502, url: release.downloadURL).localizedDescription)
            }
            progress(.downloading(ref, progress: Double(step) / 10))
            await pause(0.08)
        }
        progress(.installing(ref))
        await pause(0.3)
        var updated = current
        updated.version = release.version
        updated.releaseID = release.releaseID
        updated.assetName = release.assetName
        updated.publishedAt = release.publishedAt
        updated.installedAt = .now
        entry.previous[ref] = current
        entry.managed[ref] = updated
        entry.available[ref] = nil
        data[installation.id] = entry
        return .done(updated)
    }

    func uninstall(_ ref: AddonRef, from installation: Installation) async throws {
        var entry = try entry(installation)
        await pause(0.4)
        guard entry.managed.removeValue(forKey: ref) != nil else { throw AddonError.notInstalled(ref) }
        entry.available[ref] = nil
        entry.previous[ref] = nil
        data[installation.id] = entry
    }

    func rollback(_ ref: AddonRef, in installation: Installation) async throws {
        var entry = try entry(installation)
        await pause(0.6)
        guard let current = entry.managed[ref] else { throw AddonError.notInstalled(ref) }
        guard var previous = entry.previous[ref] else { throw AddonError.noRollbackAvailable(ref) }
        previous.installedAt = .now
        previous.pinned = current.pinned
        previous.channel = current.channel
        entry.managed[ref] = previous
        entry.previous[ref] = nil
        entry.available[ref] = Self.release(for: ref, name: current.name, version: current.version, id: current.releaseID,
                                            daysAgo: 0, changelog: "Re-install \(current.version).")
        entry.available[ref]?.publishedAt = current.publishedAt
        data[installation.id] = entry
    }

    func setPinned(_ pinned: Bool, for ref: AddonRef, in installation: Installation) async throws {
        var entry = try entry(installation)
        guard entry.managed[ref] != nil else { throw AddonError.notInstalled(ref) }
        entry.managed[ref]?.pinned = pinned
        data[installation.id] = entry
    }

    func setChannel(_ channel: Channel, for ref: AddonRef, in installation: Installation) async throws {
        var entry = try entry(installation)
        guard entry.managed[ref] != nil else { throw AddonError.notInstalled(ref) }
        entry.managed[ref]?.channel = channel
        data[installation.id] = entry
    }

    func adopt(folder: String, as ref: AddonRef, in installation: Installation) async throws -> InstalledAddon {
        var entry = try entry(installation)
        await pause(1.0)
        guard let index = entry.unmanaged.firstIndex(where: { $0.folder == folder }) else {
            throw AddonError.notInstalled(ref)
        }
        let toc = entry.unmanaged[index].toc
        nextReleaseID += 1
        let version = toc?.version ?? "1.0.0"
        let addon = InstalledAddon(
            id: ref, name: toc?.title ?? folder, folders: [folder], version: version, releaseID: nextReleaseID,
            assetName: "\(folder)-\(version).zip", publishedAt: .daysAgo(7), installedAt: .now)
        entry.unmanaged.remove(at: index)
        entry.managed[ref] = addon
        data[installation.id] = entry
        return addon
    }
}

// MARK: - Small helpers

extension AddonRef {
    fileprivate static func gh(_ identifier: String) -> AddonRef { AddonRef(source: .github, identifier: identifier) }
}

extension Date {
    fileprivate static func daysAgo(_ days: Double) -> Date { Date.now.addingTimeInterval(-days * 86_400) }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
