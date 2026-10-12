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
