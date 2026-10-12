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

/// Support badge wording. "Not checked" is the absence of a verdict for this flavor, not a
/// warning; "Unknown, no release.json" is a verdict that only an install can settle.
nonisolated enum SupportLabel {
    static func text(for status: SupportStatus, flavor: Flavor) -> String {
        switch status {
        case .supported: "✓ \(flavor.displayName)"
        case .checking: "⋯ checking"
        case .unknown: "Not checked"
        case .needsDownload: "Unknown, no release.json"
        case .unsupported: "— not yet"
        case .noReleases: "— no releases"
        }
    }

    static func help(for status: SupportStatus, flavor: Flavor) -> String {
        switch status {
        case .supported(let version): "Supports \(flavor.displayName) (\(version))"
        case .checking: "Checking for a \(flavor.displayName) build…"
        case .unknown: "Open this add-on to check \(flavor.displayName) support"
        case .needsDownload: "Its releases have no release.json, so \(flavor.displayName) support can only be confirmed by installing it"
        case .unsupported: "No \(flavor.displayName) build yet"
        case .noReleases: "This repository has no GitHub releases"
        }
    }
}
