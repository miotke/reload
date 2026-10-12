import Foundation

/// A folder in `AddOns/` that no managed add-on owns, or a group of them that one release
/// covers (docs/features/installing.md#adopting-unmanaged-folders).
public struct UnmanagedFolder: Sendable, Hashable {
    /// The folder the row is named after: for a group, the one the suggestion came from.
    public var folder: String
    /// Every folder in the group, `folder` first. Just `[folder]` unless grouped.
    public var folders: [String]
    /// The TOC the game client loads for the installation's flavor. When it loads none, the
    /// folder's first TOC, for display (`isLoaded` is then false).
    public var toc: Toc?
    /// File name of `toc`, e.g. `Questie_Camelot.toc`.
    public var tocFile: String?
    public var isLoaded: Bool
    /// `toc` is for the installation's flavor, so the game loads this add-on.
    public var supportsFlavor: Bool
    /// Hints gathered from every TOC in the folder.
    public var hints: TocHints
    /// Repositories this folder probably comes from, best first. Local only.
    public var candidates: [AdoptionCandidate]

    public init(
        folder: String, folders: [String]? = nil, toc: Toc? = nil, tocFile: String? = nil, isLoaded: Bool = false,
        supportsFlavor: Bool = false, hints: TocHints = TocHints(), candidates: [AdoptionCandidate] = []
    ) {
        self.folder = folder
        self.folders = folders ?? [folder]
        self.toc = toc
        self.tocFile = tocFile
        self.isLoaded = isLoaded
        self.supportsFlavor = supportsFlavor
        self.hints = hints
        self.candidates = candidates
    }

    /// Reads `addonsDirectory/folder` for `flavor`, with only TOC-linked GitHub repos as
    /// candidates (the catalogue adds the rest, `AdoptionIndex`).
    public init(reading folder: String, in addonsDirectory: URL, flavor: Flavor) {
        let tocs = ZipInspector.readTocs(addonFolder: addonsDirectory.appending(path: folder, directoryHint: .isDirectory), flavor: flavor)
        let hints = TocHints(tocs.all.map(\.toc))
        self.init(
            folder: folder, toc: tocs.loaded?.toc, tocFile: tocs.loaded?.name, isLoaded: tocs.isLoaded,
            supportsFlavor: tocs.supportsFlavor, hints: hints,
            candidates: hints.githubRefs.map { AdoptionCandidate(ref: $0, name: $0.repoName, reason: "TOC links to github.com/\($0.identifier)", source: .tocLink) }
        )
    }

    /// The loaded TOC's title without colour codes or version, else the folder name.
    public var title: String { toc?.displayTitle ?? folder }
    /// `## Version`, or a version written in the title.
    public var version: String? { toc?.displayVersion }
    public var suggestion: AdoptionCandidate? { candidates.first }
    public var suggestedRef: AddonRef? { suggestion?.ref }
    /// More than one candidate is as good as the best, so the user should pick.
    public var isAmbiguous: Bool { candidates.isAmbiguous }
    public var isGroup: Bool { folders.count > 1 }
}

/// Identifiers found in a folder's TOCs, each list de-duplicated in file order.
public struct TocHints: Sendable, Hashable {
    /// From `X-Website` / `X-Github` pointing at github.com.
    public var githubRefs: [AddonRef] = []
    public var curseIDs: [Int] = []
    public var wagoIDs: [String] = []
    public var wowInterfaceIDs: [Int] = []
    /// Titles without colour codes or versions.
    public var titles: [String] = []

    public init(githubRefs: [AddonRef] = [], curseIDs: [Int] = [], wagoIDs: [String] = [], wowInterfaceIDs: [Int] = [], titles: [String] = []) {
        self.githubRefs = githubRefs
        self.curseIDs = curseIDs
        self.wagoIDs = wagoIDs
        self.wowInterfaceIDs = wowInterfaceIDs
        self.titles = titles
    }

    public init(_ tocs: [Toc]) {
        func add<T: Equatable>(_ value: T?, to list: inout [T]) {
            if let value, !list.contains(value) { list.append(value) }
        }
        for toc in tocs {
            for link in [toc.website, toc.github] { add(link.flatMap(InstallStore.githubRef(fromWebsite:)), to: &githubRefs) }
            add(toc.curseProjectID.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }, to: &curseIDs)
            add(toc.wagoID.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }, to: &wagoIDs)
            add(toc.wowInterfaceID.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }, to: &wowInterfaceIDs)
            if let title = toc.displayTitle, !titles.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
                titles.append(title)
            }
        }
    }
}

/// A repository an unmanaged folder probably comes from, and why (decision 0018).
public struct AdoptionCandidate: Sendable, Hashable, Identifiable {
    /// Where the match came from, strongest first.
    public enum Source: Int, Sendable, Hashable, Comparable, CaseIterable {
        case tocLink, curseForge, wago, wowInterface, catalogueName, repoName

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var confidence: Confidence {
            switch self {
            case .tocLink, .curseForge, .wago, .wowInterface: .high
            case .catalogueName: .medium
            case .repoName: .low
            }
        }
    }

    public enum Confidence: Int, Sendable, Hashable, Comparable, CaseIterable {
        case low, medium, high

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .low: "low"
            case .medium: "medium"
            case .high: "high"
            }
        }
    }

    public var ref: AddonRef
    /// Catalogue name, else the repository name.
    public var name: String
    /// e.g. "Matched CurseForge project 334372".
    public var reason: String
    public var source: Source
    public var confidence: Confidence { source.confidence }
    public var id: AddonRef { ref }

    public init(ref: AddonRef, name: String, reason: String, source: Source) {
        self.ref = ref
        self.name = name
        self.reason = reason
        self.source = source
    }
}

extension [AdoptionCandidate] {
    /// More than one candidate shares the best confidence.
    public var isAmbiguous: Bool {
        guard let best = first?.confidence else { return false }
        return filter { $0.confidence == best }.count > 1
    }
}

/// What adopting `release` would do (`AddonManager.adoptionPreview`).
public struct AdoptionPreview: Sendable, Hashable {
    public var release: ResolvedRelease
    /// Top-level folders in the release's zip, sorted.
    public var folders: [String]
    /// Of those, the ones on disk that no managed add-on owns: adopting replaces them.
    public var replaces: [String]
    /// Ones not on disk yet.
    public var adds: [String]
    /// Ones another managed add-on owns: adopting would fail with `folderConflict`.
    public var conflicts: [String: AddonRef]
    /// Unmanaged folders the caller asked about that the release doesn't ship.
    public var notCovered: [String]

    public init(release: ResolvedRelease, folders: [String], replaces: [String], adds: [String], conflicts: [String: AddonRef] = [:], notCovered: [String] = []) {
        self.release = release
        self.folders = folders
        self.replaces = replaces
        self.adds = adds
        self.conflicts = conflicts
        self.notCovered = notCovered
    }
}

extension AddonRef {
    /// `owner/repo` → `repo`.
    public var repoName: String { identifier.split(separator: "/").last.map(String.init) ?? identifier }
}
