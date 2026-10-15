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
        var id: GameFamily { family }
    }

    /// Nil when nobody has checked: drawn as a dim "—".
    var bubbles: [Bubble]?
    var accessibilityLabel: String

    init(availableFlavors: Set<Flavor>?, flavor: Flavor) {
        let own = flavor.family
        guard let available = availableFlavors else {
            bubbles = nil
            accessibilityLabel = "Games: not checked"
            return
        }
        let families = available.families
        let bubbles = GameFamily.allCases.map { family in
            Bubble(family: family, isPresent: families.contains(family), isOwn: family == own)
        }
        self.bubbles = bubbles
        let present = bubbles.filter(\.isPresent).map(\.family.displayName)
        accessibilityLabel = present.isEmpty ? "Games: none" : "Games: " + present.joined(separator: ", ")
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
