import AddonKit
import Foundation

// Flat, pre-formatted table rows. They're built (and sorted) in the model when the data or
// the sort changes, so table cells only read stored strings, and `Equatable` lets SwiftUI
// skip rows that didn't change.

extension AddonRef {
    /// Table row ID: `AddonRef.description` ("github:owner/repo"), stable across reloads.
    nonisolated init?(rowID: String) {
        let parts = rowID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let source = SourceID(rawValue: parts[0]) else { return nil }
        self.init(source: source, identifier: parts[1])
    }
}

// MARK: - Browse

extension [SearchResult] {
    /// The same results with `support` and `availableFlavors` replaced where `answers` has
    /// them, so a database change touches only its own rows. Nil fields are left alone.
    nonisolated func patching(_ answers: [AddonRef: StoredAvailability]) -> [SearchResult] {
        map { result in
            guard let answer = answers[result.id] else { return result }
            var patched = result
            if let support = answer.support { patched.support = support }
            if let flavors = answer.availableFlavors { patched.availableFlavors = flavors }
            return patched
        }
    }
}

nonisolated struct BrowseRow: Identifiable, Hashable, Sendable {
    var id: String
    var ref: AddonRef
    var name: String
    var owner: String
    /// "by Elv · Tukui": the owner, and the source when it isn't GitHub.
    var byline: String?
    var summary: String?
    var support: SupportStatus
    var availableFlavors: Set<Flavor>?
    /// The Games column, pre-computed for the installation.
    var games: GameBubblesModel
    /// Shown dimmed: the installation's own game isn't confirmed.
    var isDimmed: Bool
    var stars: Int?
    var starsText: String
    var lastUpdated: Date?
    var updatedText: String
    /// The core's `InstallAction`, from the installation's managed list (`InstalledModel`),
    /// never from the search result.
    var action: InstallAction
    var isInstalled: Bool { action.isInstalled }
    /// Found by a live GitHub search rather than the local catalogue.
    var isFromGitHub: Bool

    init(_ result: SearchResult, flavor: Flavor, action: InstallAction? = nil, now: Date = .now) {
        id = result.id.description
        ref = result.id
        name = result.name
        owner = result.owner
        byline = AddonByline.text(owner: result.owner, source: result.id.source)
        summary = result.summary
        support = result.support
        availableFlavors = result.availableFlavors
        games = GameBubblesModel(availableFlavors: result.availableFlavors, flavor: flavor, support: result.support)
        isDimmed = !BrowseFilter.hasConfirmedBuild(result, for: flavor)
        stars = result.stars
        starsText = result.stars.map { $0.formatted() } ?? "—"
        lastUpdated = result.lastUpdated
        updatedText = result.lastUpdated.map { DayLabel.string(for: $0, now: now) } ?? "—"
        self.action = action ?? InstallAction(installed: result.installed, update: nil, availableFlavors: result.availableFlavors, flavor: flavor)
        isFromGitHub = result.origin.contains(.github)
    }
}

nonisolated enum BrowseColumn: String, SortableColumn {
    // `games` keeps the stored raw value of the support column it replaced.
    case name, games = "support", stars, updated

    func ascending(_ lhs: BrowseRow, _ rhs: BrowseRow) -> ComparisonResult {
        switch self {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .games: GameBubblesModel.ascending(lhs.games, rhs.games)
        case .stars: compareValues(lhs.stars ?? 0, rhs.stars ?? 0)
        case .updated: compareValues(lhs.lastUpdated ?? .distantPast, rhs.lastUpdated ?? .distantPast)
        }
    }

    func hasValue(_ row: BrowseRow) -> Bool {
        switch self {
        case .name: true
        case .games: row.games.isChecked
        case .stars: row.stars != nil
        case .updated: row.lastUpdated != nil
        }
    }

    static func tiebreak(_ lhs: BrowseRow, _ rhs: BrowseRow) -> ComparisonResult {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        return byName == .orderedSame ? lhs.id.compare(rhs.id) : byName
    }
}

// MARK: - Installed

nonisolated struct InstalledRow: Identifiable, Hashable, Sendable {
    /// Ascending puts what needs attention first.
    enum Condition: Int, Comparable, Sendable {
        case missingFolders, missingDependencies, updateAvailable, failed, noCompatibleRelease, pinned, upToDate, unchecked, unmanaged

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// `AddonStatus.id`: the ref string for managed add-ons, "unmanaged:<folder>" otherwise.
    var id: String
    /// Nil for unmanaged folders.
    var ref: AddonRef?
    var name: String
    /// Repository for managed add-ons, TOC title for unmanaged folders.
    var subtitle: String?
    var version: String
    /// The update's version, or "Forever build" when the update swaps a Retail build for the
    /// installation's own.
    var availableVersion: String?
    /// "Retail build" when the installed build is another game's.
    var buildText: String?
    var channel: Channel?
    var installedAt: Date?
    var installedText: String
    var isPinned: Bool
    var missingFolders: [String]
    /// Required add-ons that aren't installed (`MissingDependency.folder`), from the core.
    var missingDependencies: [String] = []
    /// "Needs BigWigs" and its tooltip, when `missingDependencies` isn't empty.
    var dependencyText: String?
    var dependencyHelp: String?
    var condition: Condition
    var failure: String?
    /// Unmanaged only: the game doesn't load this folder for the installation's flavor.
    var isNotLoaded = false

    var isManaged: Bool { ref != nil }

    init(status: AddonStatus, update: UpdateState?, flavor: Flavor, missingDependencies: [String] = [], now: Date = .now) {
        id = status.id
        isPinned = false
        missingFolders = []
        switch status {
        case .managed(let addon, let missing):
            ref = addon.id
            name = addon.name
            subtitle = addon.id.identifier
            version = addon.version
            channel = addon.channel
            installedAt = addon.installedAt
            isPinned = addon.pinned
            missingFolders = missing
            buildText = RetailBuildOffer.buildLabel(addon)
            availableVersion = UpdateOffer(installed: addon, update: update, flavor: flavor)?.label
            self.missingDependencies = missingDependencies
            dependencyText = DependencyWording.status(missingDependencies)
            dependencyHelp = DependencyWording.statusHelp(name: addon.name, folders: missingDependencies)
            if !missing.isEmpty {
                condition = .missingFolders
            } else if !missingDependencies.isEmpty {
                // The game won't load it at all, which matters more than an update.
                condition = .missingDependencies
            } else if addon.pinned {
                condition = .pinned
            } else {
                switch update {
                case .available: condition = .updateAvailable
                case .failed(let message): condition = .failed; failure = message
                case .noCompatibleRelease: condition = .noCompatibleRelease
                case .pinned: condition = .pinned
                case .upToDate: condition = .upToDate
                case nil: condition = .unchecked
                }
            }
        case .unmanaged(let unmanaged):
            name = unmanaged.title
            subtitle = Self.unmanagedSubtitle(unmanaged)
            version = unmanaged.version ?? ""
            condition = .unmanaged
            isNotLoaded = !unmanaged.supportsFlavor
        }
        installedText = installedAt.map { DayLabel.string(for: $0, now: now) } ?? "—"
    }

    /// "2 folders" for a group, the folder name when the title differs from it, else nil.
    static func unmanagedSubtitle(_ unmanaged: UnmanagedFolder) -> String? {
        if unmanaged.isGroup { return "\(unmanaged.folders.count) folders" }
        return unmanaged.title.caseInsensitiveCompare(unmanaged.folder) == .orderedSame ? nil : unmanaged.folder
    }
}

nonisolated enum InstalledColumn: String, SortableColumn {
    case name, version, channel, status, installed

    func ascending(_ lhs: InstalledRow, _ rhs: InstalledRow) -> ComparisonResult {
        switch self {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        // `localizedStandardCompare` orders numbers numerically, so 1.10 sorts after 1.9.
        case .version: lhs.version.localizedStandardCompare(rhs.version)
        case .channel: compareValues(lhs.channel?.rawValue ?? "", rhs.channel?.rawValue ?? "")
        case .status: compareValues(lhs.condition, rhs.condition)
        case .installed: compareValues(lhs.installedAt ?? .distantPast, rhs.installedAt ?? .distantPast)
        }
    }

    func hasValue(_ row: InstalledRow) -> Bool {
        switch self {
        case .name, .status: true
        case .version: !row.version.isEmpty
        case .channel: row.channel != nil
        case .installed: row.installedAt != nil
        }
    }

    static func tiebreak(_ lhs: InstalledRow, _ rhs: InstalledRow) -> ComparisonResult {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        return byName == .orderedSame ? lhs.id.compare(rhs.id) : byName
    }
}

/// Which list the Browse tab shows with an empty query.
enum BrowseHome: String, CaseIterable, Identifiable {
    case popular, recent
    var id: Self { self }

    var title: String {
        switch self {
        case .popular: "Popular"
        case .recent: "Recently Updated"
        }
    }
}
