import AddonKit
import Foundation

/// A left-aligned text table. Widths ignore ANSI escapes, so cells may be coloured.
struct Table: Sendable {
    var headers: [String]
    var rows: [[String]]
    var indent = "  "
    var spacing = 2

    func render(style: Style) -> String {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        var widths = Array(repeating: 0, count: columnCount)
        for row in [headers] + rows {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], Style.width(cell))
            }
        }
        func line(_ cells: [String]) -> String {
            var text = indent
            for (index, cell) in cells.enumerated() {
                let isLast = index == cells.count - 1
                text += isLast ? cell : ProgressBoard.pad(cell, to: widths[index] + spacing)
            }
            return text.replacing(/\s+$/, with: "")
        }
        var lines: [String] = []
        if !headers.isEmpty { lines.append(style.bold(line(headers))) }
        lines += rows.map(line)
        return lines.joined(separator: "\n")
    }
}

/// Text formatting shared by the commands. Pure, so it can be tested.
enum Format {
    /// "just now", "5 minutes ago", "2 days ago", "3 weeks ago", "4 months ago", "2 years ago".
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "just now" }
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return unit(Int(seconds / 60), "minute")
        case ..<86_400: return unit(Int(seconds / 3600), "hour")
        case ..<(7 * 86_400): return unit(Int(seconds / 86_400), "day")
        case ..<(30 * 86_400): return unit(Int(seconds / (7 * 86_400)), "week")
        case ..<(365 * 86_400): return unit(Int(seconds / (30 * 86_400)), "month")
        default: return unit(Int(seconds / (365 * 86_400)), "year")
        }
    }

    /// The GAMES column: `R F C` in fixed positions, `·` for a family with no build, the
    /// installation's own family in bold, and `—` when nobody has checked yet.
    static func games(_ flavors: Set<Flavor>?, flavor: Flavor, style: Style) -> String {
        guard let families = flavors?.families else { return style.dim("—") }
        return GameFamily.allCases.map { family in
            guard families.contains(family) else { return style.dim("·") }
            let letter = switch family {
            case .retail: style.blue(family.letter)
            case .forever: style.cyan(family.letter)
            case .classic: style.yellow(family.letter)
            }
            return family == flavor.family ? style.bold(letter) : letter
        }.joined(separator: " ")
    }

    /// "Retail build" for an add-on installed as another game's build, else nil.
    static func build(_ addon: InstalledAddon) -> String? {
        addon.installedFlavorBuild.map { "\($0.family.displayName) build" }
    }

    /// Display name for a ref: `owner/repo` for GitHub, `source:id` otherwise.
    static func ref(_ ref: AddonRef) -> String {
        ref.key
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func searchTable(_ results: [SearchResult], flavor: Flavor, style: Style, now: Date = Date()) -> String {
        let rows = results.map { result -> [String] in
            [
                result.name,
                style.dim(Format.ref(result.id)),
                games(result.availableFlavors, flavor: flavor, style: style),
                relative(result.lastUpdated, now: now),
                result.installed != nil ? style.cyan("(installed)") : "",
            ]
        }
        return Table(headers: ["NAME", "REPO", "GAMES", "UPDATED", ""], rows: rows).render(style: style)
    }

    /// `games` holds each row's available flavors by `AddonStatus.id`; missing means not checked.
    static func listTable(_ statuses: [AddonStatus], flavor: Flavor, games: [String: Set<Flavor>] = [:], style: Style) -> String {
        let rows = statuses.map { status -> [String] in
            let gamesCell = Format.games(games[status.id], flavor: flavor, style: style)
            switch status {
            case .managed(let addon, let missing):
                var notes: [String] = []
                if addon.pinned { notes.append(style.yellow("pinned")) }
                if let build = build(addon) { notes.append(style.yellow(build)) }
                if !missing.isEmpty { notes.append(style.red("missing: \(missing.joined(separator: ", "))")) }
                return [addon.name, addon.version, style.dim(ref(addon.id)), gamesCell, addon.channel.rawValue, notes.joined(separator: ", ")]
            case .unmanaged(let unmanaged):
                let source = unmanaged.suggestedRef.map { style.dim("→ \(ref($0))?") } ?? style.dim("—")
                return [unmanagedName(unmanaged), unmanaged.version ?? "—", source, gamesCell, "—", unmanagedState(unmanaged, flavor: flavor, style: style)]
            }
        }
        return Table(headers: ["NAME", "VERSION", "SOURCE", "GAMES", "CHANNEL", "STATE"], rows: rows).render(style: style)
    }

    /// The loaded TOC's title, with the folder (or group size) when that says more.
    static func unmanagedName(_ unmanaged: UnmanagedFolder) -> String {
        let title = unmanaged.title
        if unmanaged.isGroup { return "\(title) (\(unmanaged.folders.joined(separator: ", ")))" }
        return title.caseInsensitiveCompare(unmanaged.folder) == .orderedSame ? title : "\(title) (\(unmanaged.folder))"
    }

    /// "unmanaged", whether the game loads it, and why a repo is suggested.
    static func unmanagedState(_ unmanaged: UnmanagedFolder, flavor: Flavor?, style: Style) -> String {
        var parts = ["unmanaged"]
        if let flavor, !unmanaged.supportsFlavor { parts.append("not loaded by \(flavor.displayName)") }
        if let suggestion = unmanaged.suggestion {
            parts.append(unmanaged.isAmbiguous ? "\(unmanaged.candidates.count) candidates" : suggestion.reason)
        }
        return style.dim(parts.joined(separator: " · "))
    }

    static func installsTable(_ installations: [Installation], defaultID: String?, style: Style) -> String {
        let rows = installations.map { installation -> [String] in
            [
                installation.id == defaultID ? style.green("*") : " ",
                installation.id,
                installation.flavor.displayName,
                installation.gameVersion ?? "—",
                installation.root.path(percentEncoded: false),
            ]
        }
        return Table(headers: ["", "ID", "FLAVOR", "VERSION", "PATH"], rows: rows).render(style: style)
    }

    /// One `outdated` row per available update, sorted by name.
    static func outdatedTable(_ entries: [(addon: InstalledAddon, state: UpdateState)], style: Style) -> String {
        let rows = entries.compactMap { entry -> [String]? in
            guard case .available(let release) = entry.state else { return nil }
            return [entry.addon.name, entry.addon.version, style.green(release.version), entry.addon.channel.rawValue, relative(release.publishedAt)]
        }
        return Table(headers: ["NAME", "INSTALLED", "LATEST", "CHANNEL", "PUBLISHED"], rows: rows).render(style: style)
    }

    static func updateState(_ state: UpdateState, flavor: Flavor, style: Style) -> String {
        switch state {
        case .upToDate: style.dim("up to date")
        case .available(let release): style.green("→ \(release.version)")
        case .pinned: style.yellow("pinned, skipped")
        case .noCompatibleRelease: style.dim("no \(flavor.displayName) build")
        case .failed(let message): style.red("failed: \(message)")
        }
    }
}
