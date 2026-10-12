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

/// README images are a mix of screenshots and status badges; only the former belong in the gallery.
nonisolated enum ScreenshotFilter {
    private static let badgeHosts: Set<String> = [
        "img.shields.io", "shields.io", "badgen.net", "badge.fury.io", "travis-ci.org", "travis-ci.com",
        "codecov.io", "app.codacy.com", "api.codacy.com", "ci.appveyor.com", "ko-fi.com", "storage.ko-fi.com",
        "www.paypalobjects.com", "discordapp.com", "discord.com",
    ]

    static func screenshots(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            let host = url.host()?.lowercased() ?? ""
            let path = url.path(percentEncoded: false).lowercased()
            if badgeHosts.contains(host) { return false }
            // GitHub Actions status badges: …/actions/workflows/<file>/badge.svg
            if path.hasSuffix("/badge.svg") || path.contains("/badge/") { return false }
            // Mostly logos and badges, and AsyncImage can't draw them anyway.
            if path.hasSuffix(".svg") { return false }
            return true
        }
    }
}
