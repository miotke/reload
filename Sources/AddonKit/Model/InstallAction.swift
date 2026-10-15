import Foundation

/// An add-on's primary action on one installation, decided from its install record, its
/// last update state and the builds its latest release ships. Every front end shows this
/// rather than deciding itself, so Browse rows, the inspector and the CLI can't disagree.
public enum InstallAction: Hashable, Sendable {
    /// Not installed; the installation's own build is the one to install.
    case install
    /// Not installed, no build for the installation's flavor but one for `fallback` (the
    /// Retail build on Forever). Installing it needs `allowFamilyFallback` and the user's
    /// consent (docs/features/release-selection.md#retail-build-on-forever).
    case installFallbackBuild(Flavor)
    /// Installed and up to date, pinned, or not checked. `ref` is the installed record's,
    /// whose case may differ from a search result's.
    case installed(ref: AddonRef, version: String)
    /// Installed with an update available.
    case update(ref: AddonRef, version: String, to: UpdateOffer)

    /// - Parameters:
    ///   - installed: the managed add-on for this ref, if any.
    ///   - update: its last update state.
    ///   - availableFlavors: every flavor the latest release ships; nil when not checked.
    ///   - flavor: the installation's flavor.
    public init(installed: InstalledAddon?, update: UpdateState?, availableFlavors: Set<Flavor>?, flavor: Flavor) {
        guard let installed else {
            self = flavor.offeredFallbackBuild(availableFlavors: availableFlavors).map(Self.installFallbackBuild) ?? .install
            return
        }
        if let offer = UpdateOffer(installed: installed, update: update, flavor: flavor) {
            self = .update(ref: installed.id, version: installed.version, to: offer)
        } else {
            self = .installed(ref: installed.id, version: installed.version)
        }
    }

    /// The installed record's ref, or nil when not installed.
    public var installedRef: AddonRef? {
        switch self {
        case .install, .installFallbackBuild: nil
        case .installed(let ref, _), .update(let ref, _, _): ref
        }
    }

    public var isInstalled: Bool { installedRef != nil }
}

/// What an available update installs.
public enum UpdateOffer: Hashable, Sendable {
    /// A newer release of the same build.
    case version(String)
    /// The installation's own build (`flavor`), replacing a fallback build such as the Retail
    /// build on Forever, whatever its version.
    case ownBuild(Flavor)

    /// The update `installed` has on `flavor`'s installation, or nil when there's none to
    /// offer: no `.available` state, or the add-on is pinned.
    public init?(installed: InstalledAddon, update: UpdateState?, flavor: Flavor) {
        guard case .available(let release)? = update, !installed.pinned else { return nil }
        self = installed.installedFlavorBuild != nil && release.flavorBuild == nil ? .ownBuild(flavor) : .version(release.version)
    }
}

extension Flavor {
    /// The fallback build to offer when the latest release has none for this flavor but one
    /// for `fallbackFlavor` (the Retail build on Forever, decision 0019); nil otherwise or
    /// when not checked.
    public func offeredFallbackBuild(availableFlavors: Set<Flavor>?) -> Flavor? {
        guard let available = availableFlavors, let fallback = fallbackFlavor else { return nil }
        return !available.contains(self) && available.contains(fallback) ? fallback : nil
    }
}

/// Browse filtering and emphasis for one installation (docs/features/search.md#hide-incompatible).
public enum BrowseFilter {
    /// Whether "hide incompatible" hides `result`: never an installed add-on, otherwise
    /// `Flavor.hidesAsIncompatible` on its families and support.
    public static func isHidden(_ result: SearchResult, for flavor: Flavor, isInstalled: Bool) -> Bool {
        !isInstalled && flavor.hidesAsIncompatible(families: result.families, support: result.support)
    }

    /// Whether the games picker, set to `games`, hides `result`: never an installed add-on,
    /// otherwise `GameFamily.hides`. Nil shows every game.
    public static func isHidden(_ result: SearchResult, games: GameFamily?, isInstalled: Bool) -> Bool {
        guard let games, !isInstalled else { return false }
        return games.hides(families: result.families, support: result.support)
    }

    /// True when a build for the installation's flavor is confirmed: its latest release ships
    /// one, or the stored verdict says supported. Unconfirmed rows are shown de-emphasised.
    public static func hasConfirmedBuild(_ result: SearchResult, for flavor: Flavor) -> Bool {
        if result.availableFlavors?.contains(flavor) == true { return true }
        if case .supported = result.support { return true }
        return false
    }
}

extension AdoptionPreview {
    /// False when another managed add-on owns a folder the release ships: adopting would
    /// fail with `folderConflict`.
    public var canAdopt: Bool { conflicts.isEmpty }
}

extension AddonRef {
    /// A ref from user input, the same rules as `lookup`: `owner/repo`, `github:owner/repo` or a
    /// `github.com` URL (`GitHubReleaseResolver.parse`); `wowinterface:3826` or a WoWInterface
    /// page; `tukui:elvui` or a tukui.org page (docs/features/sources.md).
    public init?(parsing input: String) {
        guard let ref = GitHubReleaseResolver.parseRef(input) ?? HostedSources.parse(input) else { return nil }
        self = ref
    }

    /// The same repo, ignoring case: GitHub names are case-insensitive, and search results
    /// don't always match the stored case.
    public func isSameRepo(as other: AddonRef) -> Bool {
        source == other.source && identifier.caseInsensitiveCompare(other.identifier) == .orderedSame
    }
}

extension BrowseFilter {
    /// `AddonManager.visibleCheckTargets`, for front ends that only know `AddonManaging`.
    public static func visibleCheckTargets(_ onScreen: [AddonRef], isChecked: (AddonRef) -> Bool) -> [AddonRef] {
        AddonManager.visibleCheckTargets(onScreen, isChecked: isChecked)
    }
}
