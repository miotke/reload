import Foundation

/// Suggests repositories for unmanaged folders from their TOC hints and the local catalogue,
/// and groups folders one release covers (docs/decisions/0018-adoption-suggestions-from-toc-hints.md).
/// Pure and local: it never touches the network.
public struct AdoptionIndex: Sendable {
    /// Candidates beyond this many aren't worth a picker row.
    public static let maxCandidates = 5

    private var byCurse: [Int: [CatalogueEntry]] = [:]
    private var byWago: [String: [CatalogueEntry]] = [:]
    private var byWoWI: [Int: [CatalogueEntry]] = [:]
    private var byName: [String: [CatalogueEntry]] = [:]
    private var byRepo: [String: [CatalogueEntry]] = [:]
    private var byFullName: [String: CatalogueEntry] = [:]

    public init(entries: [CatalogueEntry]) {
        for entry in entries {
            if let id = entry.curseID { byCurse[id, default: []].append(entry) }
            if let id = entry.wagoID, !id.isEmpty { byWago[id.lowercased(), default: []].append(entry) }
            if let id = entry.wowiID { byWoWI[id, default: []].append(entry) }
            byName[entry.name.lowercased(), default: []].append(entry)
            byRepo[entry.ref.repoName.lowercased(), default: []].append(entry)
            byFullName[entry.fullName.lowercased()] = entry
        }
        // Most recently updated first, so forks rank below the project they copy.
        func order(_ list: [CatalogueEntry]) -> [CatalogueEntry] {
            list.sorted {
                let (a, b) = ($0.lastUpdated ?? .distantPast, $1.lastUpdated ?? .distantPast)
                return a != b ? a > b : $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending
            }
        }
        byCurse = byCurse.mapValues(order)
        byWago = byWago.mapValues(order)
        byWoWI = byWoWI.mapValues(order)
        byName = byName.mapValues(order)
        byRepo = byRepo.mapValues(order)
    }

    /// Candidates for one folder, best first, at most `maxCandidates`, each repo once with
    /// its strongest reason. Order of sources: TOC GitHub link, CurseForge ID, Wago ID,
    /// WoWInterface ID, exact catalogue name (folder or title), repository name.
    public func candidates(folder: String, hints: TocHints) -> [AdoptionCandidate] {
        var found: [AdoptionCandidate] = []
        func add(_ ref: AddonRef, _ reason: String, _ source: AdoptionCandidate.Source) {
            guard !found.contains(where: { $0.ref.identifier.caseInsensitiveCompare(ref.identifier) == .orderedSame }) else { return }
            let entry = byFullName[ref.identifier.lowercased()]
            found.append(AdoptionCandidate(ref: entry?.ref ?? ref, name: entry?.name ?? ref.repoName, reason: reason, source: source))
        }
        for ref in hints.githubRefs { add(ref, "TOC links to github.com/\(ref.identifier)", .tocLink) }
        for id in hints.curseIDs {
            for entry in byCurse[id] ?? [] { add(entry.ref, "Matched CurseForge project \(id)", .curseForge) }
        }
        for id in hints.wagoIDs {
            for entry in byWago[id.lowercased()] ?? [] { add(entry.ref, "Matched Wago project \(id)", .wago) }
        }
        for id in hints.wowInterfaceIDs {
            for entry in byWoWI[id] ?? [] { add(entry.ref, "Matched WoWInterface project \(id)", .wowInterface) }
        }
        let titles = hints.titles.filter { $0.caseInsensitiveCompare(folder) != .orderedSame }
        for entry in byName[folder.lowercased()] ?? [] { add(entry.ref, "Matched folder name", .catalogueName) }
        for title in titles {
            for entry in byName[title.lowercased()] ?? [] { add(entry.ref, "Matched TOC title “\(title)”", .catalogueName) }
        }
        for entry in byRepo[folder.lowercased()] ?? [] { add(entry.ref, "Matched repository name", .repoName) }
        for title in titles {
            for entry in byRepo[title.lowercased()] ?? [] { add(entry.ref, "Matched repository name to TOC title", .repoName) }
        }
        return Array(found.prefix(Self.maxCandidates))
    }

    /// `folder` with the catalogue's candidates added after its TOC links.
    public func suggesting(_ folder: UnmanagedFolder) -> UnmanagedFolder {
        var folder = folder
        folder.candidates = candidates(folder: folder.folder, hints: folder.hints)
        return folder
    }

    // MARK: - Grouping

    /// Merges folders that one suggested release covers into a single entry named after the
    /// folder the suggestion came from (docs/architecture/data-storage.md#reconcile).
    ///
    /// - A release's known folders (`releaseFolders`, lower-cased `owner/repo` → the folders
    ///   its zip shipped when last downloaded) pull in every unmanaged folder they name.
    /// - Without that, folders whose own unambiguous best suggestion is the same repo group.
    /// - Anything else stays on its own, with its own suggestion.
    public static func group(_ folders: [UnmanagedFolder], releaseFolders: [String: [String]]) -> [UnmanagedFolder] {
        // Strongest suggestions claim folders first.
        let leaders = folders.enumerated()
            .filter { $0.element.suggestion != nil && !$0.element.isAmbiguous }
            .sorted { a, b in
                let (x, y) = (a.element.suggestion!, b.element.suggestion!)
                return x.source != y.source ? x.source < y.source : a.offset < b.offset
            }
        var claimed: [Int: Int] = [:]  // member index → leader index
        for (index, leader) in leaders where claimed[index] == nil {
            let ref = leader.suggestedRef!
            let shipped = Set((releaseFolders[ref.identifier.lowercased()] ?? []).map { $0.lowercased() })
            guard shipped.isEmpty || shipped.contains(leader.folder.lowercased()) else { continue }
            claimed[index] = index
            for (other, folder) in folders.enumerated() where other != index && claimed[other] == nil {
                let sameRef = !folder.isAmbiguous && folder.suggestedRef.map { $0.identifier.caseInsensitiveCompare(ref.identifier) == .orderedSame } == true
                let covered = shipped.isEmpty ? sameRef : shipped.contains(folder.folder.lowercased())
                if covered { claimed[other] = index }
            }
        }
        var result: [UnmanagedFolder] = []
        for (index, folder) in folders.enumerated() {
            guard let leader = claimed[index] else {
                result.append(folder)
                continue
            }
            guard leader == index else { continue }
            var merged = folder
            let members = folders.indices.filter { claimed[$0] == index && $0 != index }.map { folders[$0].folder }
            merged.folders = [folder.folder] + members.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            result.append(merged)
        }
        return result
    }
}
