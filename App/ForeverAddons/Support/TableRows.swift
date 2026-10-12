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

nonisolated struct BrowseRow: Identifiable, Hashable, Sendable {
    var id: String
    var ref: AddonRef
    var name: String
    var owner: String
    var summary: String?
    var support: SupportStatus
    var stars: Int?
    var starsText: String
    var lastUpdated: Date?
    var updatedText: String
    var isInstalled: Bool
    /// Found by a live GitHub search rather than the local catalogue.
    var isFromGitHub: Bool

    init(_ result: SearchResult, now: Date = .now) {
        id = result.id.description
        ref = result.id
        name = result.name
        owner = result.owner
        summary = result.summary
        support = result.support
        stars = result.stars
        starsText = result.stars.map { $0.formatted() } ?? "—"
        lastUpdated = result.lastUpdated
        updatedText = result.lastUpdated.map { DayLabel.string(for: $0, now: now) } ?? "—"
        isInstalled = result.installed != nil
        isFromGitHub = result.origin.contains(.github)
    }
}

nonisolated enum BrowseColumn: String, SortableColumn {
    case name, support, stars, updated

    func ascending(_ lhs: BrowseRow, _ rhs: BrowseRow) -> ComparisonResult {
        switch self {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .support: compareValues(Self.supportRank(lhs.support), Self.supportRank(rhs.support))
        case .stars: compareValues(lhs.stars ?? 0, rhs.stars ?? 0)
        case .updated: compareValues(lhs.lastUpdated ?? .distantPast, rhs.lastUpdated ?? .distantPast)
        }
    }

    func hasValue(_ row: BrowseRow) -> Bool {
        switch self {
        case .name, .support: true
        case .stars: row.stars != nil
        case .updated: row.lastUpdated != nil
        }
    }

    static func tiebreak(_ lhs: BrowseRow, _ rhs: BrowseRow) -> ComparisonResult {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        return byName == .orderedSame ? lhs.id.compare(rhs.id) : byName
    }

    /// Ascending puts confirmed Forever support first.
    static func supportRank(_ status: SupportStatus) -> Int {
        switch status {
        case .supported: 0
        case .checking: 1
        case .needsDownload: 2
        case .unknown: 3
        case .unsupported: 4
        case .noReleases: 5
        }
    }
}

// MARK: - Installed

nonisolated struct InstalledRow: Identifiable, Hashable, Sendable {
    /// Ascending puts what needs attention first.
    enum Condition: Int, Comparable, Sendable {
        case missingFolders, updateAvailable, failed, noCompatibleRelease, pinned, upToDate, unchecked, unmanaged

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
    var availableVersion: String?
    var channel: Channel?
    var installedAt: Date?
    var installedText: String
    var isPinned: Bool
    var missingFolders: [String]
    var condition: Condition
    var failure: String?

    var isManaged: Bool { ref != nil }

    init(status: AddonStatus, update: UpdateState?, now: Date = .now) {
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
            if case .available(let release) = update, !addon.pinned { availableVersion = release.version }
            if !missing.isEmpty {
                condition = .missingFolders
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
        case .unmanaged(let folder, let toc, _):
            name = folder
            subtitle = toc?.title.flatMap { $0 == folder ? nil : $0 }
            version = toc?.version ?? ""
            condition = .unmanaged
        }
        installedText = installedAt.map { DayLabel.string(for: $0, now: now) } ?? "—"
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
