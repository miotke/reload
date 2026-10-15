import Foundation

/// Ranks the add-ons that could provide a missing dependency folder
/// (docs/features/dependencies.md#candidates). Pure: callers look the matches up locally and
/// drop sources that are off.
enum DependencyMatcher {
    /// An add-on whose last downloaded release shipped the folder (`release_folders`).
    struct Downloaded: Sendable, Hashable {
        var ref: AddonRef
        var name: String
    }

    /// Candidates for `folder`, best first, at most `AdoptionIndex.maxCandidates`, and the one
    /// certain enough to install without a choice:
    ///
    /// 1. `downloaded`: releases seen to ship the folder. Strong.
    /// 2. `listed`: hosted listings that name the folder. Strong.
    /// 3. `named`: catalogue name matches (`AdoptionIndex` with no TOC hints). Weak.
    ///
    /// `suggested` is the only candidate of the first strong tier that has any, or, with no
    /// strong match at all, the only candidate when its name is the folder's. Two matches in
    /// that tier, or several weak ones, suggest nothing.
    ///
    /// `preferredSource` (where the add-ons that need the folder come from) goes first: when
    /// exactly one candidate from it is named after the folder, it's suggested and listed
    /// first. LittleWigs from GitHub gets GitHub's BigWigs, not WoWInterface's copy, so one
    /// family of add-ons doesn't straddle two hosts with different release timing.
    static func rank(
        folder: String, downloaded: [Downloaded], listed: [CatalogueEntry], named: [AdoptionCandidate],
        preferredSource: SourceID? = nil
    ) -> (candidates: [DependencyCandidate], suggested: DependencyCandidate?) {
        func isFolder(_ name: String) -> Bool { name.caseInsensitiveCompare(folder) == .orderedSame }

        var seen = Set<String>()
        func unique(_ candidates: [DependencyCandidate]) -> [DependencyCandidate] {
            candidates.filter { seen.insert($0.ref.key.lowercased()).inserted }
        }

        let fromDownloads = unique(downloaded
            .sorted { a, b in
                isFolder(a.name) != isFolder(b.name) ? isFolder(a.name)
                    : a.ref.key.localizedStandardCompare(b.ref.key) == .orderedAscending
            }
            .map { DependencyCandidate(ref: $0.ref, name: $0.name, reason: "Its download shipped the \(folder) folder") })
        let fromListings = unique(listed
            .sorted { a, b in
                if isFolder(a.name) != isFolder(b.name) { return isFolder(a.name) }
                let (x, y) = (a.lastUpdated ?? .distantPast, b.lastUpdated ?? .distantPast)
                return x != y ? x > y : a.fullName.localizedStandardCompare(b.fullName) == .orderedAscending
            }
            .map { DependencyCandidate(ref: $0.ref, name: $0.name, reason: "\($0.source.displayName) lists the \(folder) folder") })
        let fromNames = unique(named.compactMap { match in
            switch match.source {
            case .catalogueName: DependencyCandidate(ref: match.ref, name: match.name, reason: "Named \(folder) in the catalogue")
            case .repoName: DependencyCandidate(ref: match.ref, name: match.name, reason: "Its repository is named \(folder)")
            default: nil
            }
        })

        var candidates = Array((fromDownloads + fromListings + fromNames).prefix(AdoptionIndex.maxCandidates))
        let sameSource = (fromDownloads + fromListings + fromNames).filter { candidate in
            candidate.ref.source == preferredSource && (isFolder(candidate.name) || isFolder(candidate.ref.repoName))
        }
        if sameSource.count == 1 {
            let preferred = sameSource[0]
            candidates = Array(([preferred] + candidates.filter { $0.ref != preferred.ref }).prefix(AdoptionIndex.maxCandidates))
            return (candidates, preferred)
        }
        let suggested: DependencyCandidate?
        if !fromDownloads.isEmpty {
            suggested = fromDownloads.count == 1 ? fromDownloads[0] : nil
        } else if !fromListings.isEmpty {
            suggested = fromListings.count == 1 ? fromListings[0] : nil
        } else if fromNames.count == 1, isFolder(fromNames[0].name) || isFolder(fromNames[0].ref.repoName) {
            suggested = fromNames[0]
        } else {
            suggested = nil
        }
        return (candidates, suggested)
    }
}
