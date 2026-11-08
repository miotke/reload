import Foundation

/// Repos that publish several things from one repo, told apart by tag prefix:
/// `spoken/v3.8.4` (an add-on), `places-audio/v2.1.0` (its voice pack), `manager/v0.1.12`
/// (a desktop app) (docs/features/optional-parts.md). Pure; no I/O.
public enum ReleaseStreams {
    /// Stable releases and prereleases kept per prefix in a stored listing: enough to walk
    /// back past a release without a usable zip.
    static let keptStablePerStream = 3
    static let keptPrereleasesPerStream = 2
    /// Release notes are kept this long per release in a stored listing.
    static let keptBodyLength = 4_000

    /// `places-audio` for `places-audio/v2.1.0`; nil for a tag without one (`v1.2`, `manager-latest`).
    public static func prefix(ofTag tag: String) -> String? {
        guard let slash = tag.firstIndex(of: "/"), slash > tag.startIndex, tag.index(after: slash) < tag.endIndex else { return nil }
        return String(tag[..<slash])
    }

    /// True when `tag` is `<prefix>/…`, ignoring case.
    public static func isInStream(_ tag: String, prefix: String) -> Bool {
        self.prefix(ofTag: tag)?.caseInsensitiveCompare(prefix) == .orderedSame
    }

    /// The stream an installed add-on follows: its ref's prefix, else the installed tag's.
    /// A plain ref installed at `spoken/v3.8.4` keeps to `spoken/…` tags, so it never moves to
    /// another stream of the same repo (a desktop app or a voice pack).
    public static func followedPrefix(ref: AddonRef, installedTag: String?) -> String? {
        guard ref.source == .github else { return nil }
        return ref.tagPrefix ?? installedTag.flatMap(prefix(ofTag:))
    }

    static func releases(_ releases: [GitHubRelease], inStream prefix: String) -> [GitHubRelease] {
        releases.filter { isInStream($0.tagName, prefix: prefix) }
    }

    /// The version part of a tag: `2.1.0` for `places-audio/v2.1.0`, `1.2` for `v1.2`.
    static func version(ofTag tag: String) -> String {
        var rest = prefix(ofTag: tag).map { tag.dropFirst($0.count + 1) } ?? tag[...]
        if let first = rest.first, first == "v" || first == "V", rest.dropFirst().first?.isNumber == true { rest = rest.dropFirst() }
        return String(rest)
    }

    /// An asset's name without its release's version, lower-cased: `spoken-.zip` for
    /// `Spoken-3.8.4.zip` of `spoken/v3.8.4`, so the next release's zip compares equal while
    /// `SpokenQuests-WoW_1.12-2.2.2.zip` and `SpokenQuests-WoW_2.4.3-2.2.2.zip` stay apart.
    static func stem(of assetName: String, tag: String) -> String {
        let name = assetName.lowercased()
        let version = version(ofTag: tag).lowercased()
        return version.isEmpty ? name : name.replacingOccurrences(of: version, with: "")
    }

    // MARK: - Desktop apps

    static let desktopExtensions = [".dmg", ".pkg", ".exe", ".msi", ".appimage", ".deb", ".rpm", ".snap", ".flatpak"]
    static let platformTokens: Set<String> = [
        "mac", "macos", "osx", "darwin", "win", "win32", "win64", "windows", "linux", "arm64", "aarch64", "x64", "x86", "amd64",
    ]

    /// True for a release that ships a desktop installer (`.dmg`, `.exe`, `.AppImage` …): its
    /// zips are app builds, never add-ons, so they're never downloaded to be inspected.
    static func shipsDesktopApp(_ release: GitHubRelease) -> Bool {
        release.uploadedAssets.contains { asset in
            let name = asset.name.lowercased()
            return desktopExtensions.contains { name.hasSuffix($0) }
        }
    }

    /// True for a zip named for an operating system or CPU (`App-0.1.12-mac-arm64.zip`).
    static func isPlatformBuild(_ assetName: String) -> Bool {
        let base = assetName.lowercased().replacingOccurrences(of: ".zip", with: "")
        return base.split(whereSeparator: { "-_. ".contains($0) }).contains { platformTokens.contains(String($0)) }
    }

    // MARK: - Optional parts

    /// The stream whose latest stable release publishes `folder`.
    struct PartMatch: Sendable, Hashable {
        var prefix: String
        var release: GitHubRelease
        var asset: GitHubAsset
    }

    /// The one stream whose latest stable release has a zip named for `folder`: the name
    /// starts with the folder name, case-insensitively, followed by `-` or `_`. A name that
    /// continues with a version (`SpokenZonesAudio-2.0.1.zip`) beats one that continues with
    /// anything else (`SpokenZonesAudio_deDE-2.1.1.zip`, a language pack). Two streams
    /// equally good means no match: guessing would install the wrong 1 GB pack.
    /// Streams in `excluding` (the add-on's own) never match.
    static func match(folder: String, in releases: [GitHubRelease], excluding: Set<String> = []) -> PartMatch? {
        let wanted = folder.lowercased()
        let skipped = Set(excluding.map { $0.lowercased() })
        var exact: [String: PartMatch] = [:]
        var loose: [String: PartMatch] = [:]
        for (prefix, release) in latestStable(releases) where !skipped.contains(prefix.lowercased()) {
            for asset in release.uploadedAssets {
                let name = asset.name.lowercased()
                guard name.hasSuffix(".zip"), name.hasPrefix(wanted) else { continue }
                let rest = name.dropFirst(wanted.count)
                guard let separator = rest.first, separator == "-" || separator == "_" else { continue }
                let tail = rest.dropFirst()
                let versioned = tail.first?.isNumber == true || (tail.first == "v" && tail.dropFirst().first?.isNumber == true)
                let found = PartMatch(prefix: prefix, release: release, asset: asset)
                if versioned {
                    exact[prefix.lowercased()] = exact[prefix.lowercased()] ?? found
                } else {
                    loose[prefix.lowercased()] = loose[prefix.lowercased()] ?? found
                }
            }
        }
        let tier = exact.isEmpty ? loose : exact
        return tier.count == 1 ? tier.first?.value : nil
    }

    /// The newest stable, non-draft release of each prefix, in listing order.
    static func latestStable(_ releases: [GitHubRelease]) -> [(prefix: String, release: GitHubRelease)] {
        var seen = Set<String>()
        var out: [(String, GitHubRelease)] = []
        for release in releases where !release.draft && !release.prerelease {
            guard let prefix = prefix(ofTag: release.tagName), seen.insert(prefix.lowercased()).inserted else { continue }
            out.append((prefix, release))
        }
        return out
    }

    /// What a stored listing keeps: releases with a tag prefix, per prefix the newest
    /// `keptStablePerStream` stable releases and `keptPrereleasesPerStream` prereleases, no
    /// drafts, notes capped at `keptBodyLength`. About 1 KB per release instead of the API's 6.
    static func trimmed(_ releases: [GitHubRelease]) -> [GitHubRelease] {
        var stable: [String: Int] = [:]
        var pre: [String: Int] = [:]
        var out: [GitHubRelease] = []
        for var release in releases where !release.draft {
            guard let prefix = prefix(ofTag: release.tagName)?.lowercased() else { continue }
            if release.prerelease {
                guard pre[prefix, default: 0] < keptPrereleasesPerStream else { continue }
                pre[prefix, default: 0] += 1
            } else {
                guard stable[prefix, default: 0] < keptStablePerStream else { continue }
                stable[prefix, default: 0] += 1
            }
            if let body = release.body, body.count > keptBodyLength { release.body = String(body.prefix(keptBodyLength)) }
            out.append(release)
        }
        return out
    }
}

/// A repo's releases with a tag prefix, as `LatestReleaseStore.listing` stores them
/// (docs/features/optional-parts.md#the-release-listing).
struct ReleaseListing: Sendable, Hashable, Codable {
    /// Newest first, trimmed by `ReleaseStreams.trimmed`.
    var releases: [GitHubRelease]
    /// Of the first page, for the next revalidation.
    var etag: String?
    var checkedAt: Date
    /// The repo's latest stable tag (`releases/latest`) when this was fetched. While it's
    /// unchanged no stable release was published in any stream, so the listing is current.
    var latestTag: String?
    /// The repo doesn't exist (404).
    var notFound = false
    /// The last revalidation failed then; `releases` are from before it.
    var failedAt: Date?

    func releases(inStream prefix: String) -> [GitHubRelease] {
        ReleaseStreams.releases(releases, inStream: prefix)
    }
}
