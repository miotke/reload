import AddonKit
import Foundation

/// Calendar-day labels for dates in tables and the inspector. A relative "3 seconds ago"
/// reads as noise for an install date, and mixed relative phrases ("last month", "2 months
/// ago") don't scan as a column, so these are "Today" or a short date.
nonisolated enum DayLabel {
    static func string(
        for date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                                     timeZone: calendar.timeZone)
        return date.formatted(style)
    }
}

/// The Browse status bar's "Last fetched …": a short date and time, "Today, 7:18 AM" for today.
nonisolated enum FetchLabel {
    static func string(
        for date: Date?, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let date else { return "Not fetched yet" }
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "Last fetched Today, \(time)" }
        var day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return "Last fetched \(date.formatted(day)), \(time)"
    }
}

/// The R / F / C bubbles for one add-on (docs/app/layout.md#games), pre-computed so a table
/// cell only reads stored values. Three fixed positions, so columns line up.
nonisolated struct GameBubblesModel: Hashable, Sendable {
    struct Bubble: Hashable, Sendable, Identifiable {
        var family: GameFamily
        var isPresent: Bool
        /// The installation's own family: drawn with a bolder fill.
        var isOwn: Bool
        var help: String
        var id: GameFamily { family }
    }

    /// Nil when nobody has checked: drawn as a dim "—".
    var bubbles: [Bubble]?
    /// Tooltip for the "—".
    var uncheckedHelp: String
    var accessibilityLabel: String

    init(availableFlavors: Set<Flavor>?, flavor: Flavor, support: SupportStatus = .unknown) {
        let own = flavor.family
        uncheckedHelp = switch support {
        case .noReleases: "This repository has no GitHub releases"
        case .needsDownload: "Not checked: its releases have no release.json, so this shows once it's installed"
        default: "Not checked yet. Shown once the add-on is opened, refreshed or scrolled into view"
        }
        guard let available = availableFlavors else {
            bubbles = nil
            accessibilityLabel = "Games: not checked"
            return
        }
        let families = available.families
        let bubbles = GameFamily.allCases.map { family in
            Bubble(family: family, isPresent: families.contains(family), isOwn: family == own,
                   help: Self.help(family, available: available, installation: flavor))
        }
        self.bubbles = bubbles
        let present = bubbles.filter(\.isPresent).map(\.family.displayName)
        accessibilityLabel = present.isEmpty ? "Games: none" : "Games: " + present.joined(separator: ", ")
    }

    /// "Classic: Era, TBC Anniversary, Wrath, Cata, Mists", "No Forever build", and on Forever
    /// the out-of-date caveat for a Retail build.
    static func help(_ family: GameFamily, available: Set<Flavor>, installation flavor: Flavor) -> String {
        let present = family.flavors.filter(available.contains)
        guard !present.isEmpty else { return "No \(family.displayName) build" }
        switch family {
        case .classic:
            return "Classic: " + present.map(\.shortName).joined(separator: ", ")
        case .retail where flavor == .forever:
            return "Retail build: may work on Forever, which lists it as out of date until you tick Load out of date AddOns"
        case .retail, .forever:
            return "\(family.displayName) build"
        }
    }

    var isChecked: Bool { bubbles != nil }
    /// The installation's own family has a build.
    var ownFamilyPresent: Bool { bubbles?.contains { $0.isOwn && $0.isPresent } ?? false }
    var familyCount: Int { bubbles?.filter(\.isPresent).count ?? 0 }

    /// Ascending puts the own family first, then the most games; unchecked rows have no value.
    static func ascending(_ lhs: Self, _ rhs: Self) -> ComparisonResult {
        if lhs.ownFamilyPresent != rhs.ownFamilyPresent { return lhs.ownFamilyPresent ? .orderedAscending : .orderedDescending }
        return compareValues(rhs.familyCount, lhs.familyCount)
    }
}

/// The Browse filter toggle, by the installation's game family. Its `@AppStorage` key is still
/// `browseForeverOnly`, so the setting carries over.
nonisolated enum IncompatibleFilterLabel {
    static func title(for flavor: Flavor) -> String {
        switch flavor.family {
        case .forever: "Hide Classic-only"
        case .retail, .classic: "Hide add-ons without a \(flavor.family.displayName) build"
        }
    }

    static func help(for flavor: Flavor) -> String {
        switch flavor.family {
        case .forever:
            "Hide add-ons that only ship Classic builds; they don't load on \(flavor.displayName). Retail-only add-ons stay: they often work, listed as out of date."
        case .retail, .classic:
            "Hide add-ons whose latest release has no \(flavor.family.displayName) build, so they won't load on \(flavor.displayName). Add-ons not checked yet stay."
        }
    }
}

extension UpdateOffer {
    /// "v1.3", or "Forever build" when the update replaces a fallback build with the installation's own.
    nonisolated var label: String {
        switch self {
        case .version(let version): version
        case .ownBuild(let flavor): "\(flavor.displayName) build"
        }
    }
}

/// Wording for the fallback (Retail) build on Forever; whether it's offered is the core's
/// `InstallAction.installFallbackBuild` (decision 0019).
nonisolated enum RetailBuildOffer {
    /// "Retail build" for an add-on installed as another game's build, else nil.
    static func buildLabel(_ addon: InstalledAddon) -> String? {
        addon.installedFlavorBuild.map { "\($0.family.displayName) build" }
    }

    static func explanation(for flavor: Flavor) -> String {
        "This add-on has no \(flavor.displayName) build. \(flavor.displayName) can load its Retail build, but lists it as out of date: tick Load out of date AddOns on the character select AddOns screen to enable it. Some Retail add-ons still break, since a few game APIs differ. Updates keep to the Retail build until a \(flavor.displayName) build appears."
    }
}
