import Foundation

/// What the caller knows about a release's `release.json` asset.
public enum ReleaseJSONState: Sendable, Hashable {
    case available(ReleaseJSON)
    /// Not downloaded yet; the selector asks for it with `.needsReleaseJSON`.
    case notLoaded
    /// Download or decoding failed; the release is treated as having no release.json.
    case unavailable
}

public enum ReleaseSelection: Sendable, Hashable {
    /// `asset` is the zip to install.
    case selected(release: GitHubRelease, asset: GitHubAsset, reasoning: [String])
    /// Fetch `asset` (the release.json) and call `select` again.
    case needsReleaseJSON(release: GitHubRelease, asset: GitHubAsset, reasoning: [String])
    /// No release.json: download `candidates` in order and inspect their TOCs. If none match,
    /// add `release.id` to `excluding` and call `select` again.
    case needsInspection(release: GitHubRelease, candidates: [GitHubAsset], reasoning: [String])
    /// No release supports the flavor.
    case none(reasoning: [String])

    public var reasoning: [String] {
        switch self {
        case .selected(_, _, let r), .needsReleaseJSON(_, _, let r), .needsInspection(_, _, let r), .none(let r): r
        }
    }
}

/// Picks the newest release that supports a flavor (docs/design.md §6.5). Pure; no I/O.
///
/// Callers loop: fetch release.json / inspect zips as asked, then call `select` again
/// with the new knowledge, until `.selected` or `.none`.
public enum ReleaseSelector {
    /// Releases eligible for `channel`, newest first, without drafts (and prereleases on `.stable`).
    public static func eligible(_ releases: [GitHubRelease], channel: Channel) -> [GitHubRelease] {
        releases.filter { !$0.draft && (channel == .prerelease || !$0.prerelease) }
    }

    /// - Parameters:
    ///   - releases: Decoded releases, newest first.
    ///   - releaseJSON: State of a release.json asset, looked up by asset.
    ///   - excluding: Release ids already rejected by the caller (e.g. zip inspection found nothing).
    public static func select(
        _ releases: [GitHubRelease], channel: Channel, flavor: Flavor,
        releaseJSON: (GitHubAsset) -> ReleaseJSONState, excluding: Set<Int64> = []
    ) -> ReleaseSelection {
        var reasoning: [String] = []
        for release in releases {
            if release.draft {
                reasoning.append("skipped draft \(release.label)")
                continue
            }
            if release.prerelease && channel != .prerelease {
                reasoning.append("skipped prerelease \(release.label)")
                continue
            }
            if excluding.contains(release.id) {
                reasoning.append("release \(release.label): no \(flavor.rawValue) zip found")
                continue
            }
            reasoning.append("release \(release.label)")

            if let jsonAsset = release.releaseJSONAsset {
                switch releaseJSON(jsonAsset) {
                case .notLoaded:
                    return .needsReleaseJSON(release: release, asset: jsonAsset, reasoning: reasoning)
                case .available(let json):
                    guard let entry = json.release(for: flavor) else {
                        reasoning.append("release.json has no \(flavor.rawValue) entry; trying older release")
                        continue
                    }
                    guard let asset = release.uploadedAssets.first(where: { $0.name == entry.filename }) else {
                        reasoning.append("release.json names \(entry.filename), but no such asset; trying older release")
                        continue
                    }
                    let interfaces = entry.metadata
                        .filter { flavor.rules.releaseJSONFlavors.contains($0.flavor.lowercased()) }
                        .map { String($0.interface) }
                        .joined(separator: ", ")
                    reasoning.append("release.json → \(asset.name) (\(flavor.rawValue) \(interfaces))")
                    return .selected(release: release, asset: asset, reasoning: reasoning)
                case .unavailable:
                    reasoning.append("release.json couldn't be read; inspecting zips")
                }
            }

            let candidates = zipCandidates(release, flavor: flavor)
            if candidates.isEmpty {
                reasoning.append("no zip assets; trying older release")
                continue
            }
            reasoning.append("no release.json; candidates: " + candidates.map(\.name).joined(separator: ", "))
            return .needsInspection(release: release, candidates: candidates, reasoning: reasoning)
        }
        reasoning.append(releases.isEmpty ? "no releases" : "no release supports \(flavor.rawValue)")
        return .none(reasoning: reasoning)
    }

    /// Convenience: release.json contents keyed by asset id; missing ids are `.notLoaded`.
    public static func select(
        _ releases: [GitHubRelease], channel: Channel, flavor: Flavor,
        releaseJSONs: [Int64: ReleaseJSON], excluding: Set<Int64> = []
    ) -> ReleaseSelection {
        select(releases, channel: channel, flavor: flavor, releaseJSON: { asset in
            releaseJSONs[asset.id].map(ReleaseJSONState.available) ?? .notLoaded
        }, excluding: excluding)
    }

    /// Uploaded `.zip` assets without `-nolib`, with names mentioning the flavor first.
    public static func zipCandidates(_ release: GitHubRelease, flavor: Flavor) -> [GitHubAsset] {
        let zips = release.uploadedAssets.filter {
            let name = $0.name.lowercased()
            return name.hasSuffix(".zip") && !name.contains("-nolib")
        }
        let hints = (flavor.rules.tocSuffixes + flavor.rules.releaseJSONFlavors).map { $0.lowercased() }
        let preferred = zips.filter { asset in hints.contains { asset.name.lowercased().contains($0) } }
        return preferred + zips.filter { !preferred.contains($0) }
    }
}
