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

    static func support(_ status: SupportStatus, style: Style) -> String {
        switch status {
        case .supported(let version): style.green("✓ \(version)")
        case .unsupported: style.dim("— not yet")
        case .noReleases: style.dim("— no releases")
        case .needsDownload: style.yellow("? needs download")
        case .checking: style.dim("… checking")
        case .unknown: style.yellow("? unknown")
        }
    }

    /// Display name for a ref: `owner/repo` for GitHub, `source:id` otherwise.
    static func ref(_ ref: AddonRef) -> String {
        ref.source == .github ? ref.identifier : ref.description
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func searchTable(_ results: [SearchResult], style: Style, now: Date = Date()) -> String {
        let rows = results.map { result -> [String] in
            [
                result.name,
                style.dim(Format.ref(result.id)),
                support(result.support, style: style),
                relative(result.lastUpdated, now: now),
                result.installed != nil ? style.cyan("(installed)") : "",
            ]
        }
        return Table(headers: ["NAME", "REPO", "FOREVER", "UPDATED", ""], rows: rows).render(style: style)
    }

    static func listTable(_ statuses: [AddonStatus], style: Style) -> String {
        let rows = statuses.map { status -> [String] in
            switch status {
            case .managed(let addon, let missing):
                var state = addon.pinned ? style.yellow("pinned") : ""
                if !missing.isEmpty {
                    let note = style.red("missing: \(missing.joined(separator: ", "))")
                    state = state.isEmpty ? note : state + ", " + note
                }
                return [addon.name, addon.version, style.dim(ref(addon.id)), addon.channel.rawValue, state]
            case .unmanaged(let folder, let toc, let suggested):
                let source = suggested.map { style.dim("→ \(ref($0))?") } ?? style.dim("—")
                return [folder, toc?.version ?? "—", source, "—", style.dim("unmanaged")]
            }
        }
        return Table(headers: ["NAME", "VERSION", "SOURCE", "CHANNEL", "STATE"], rows: rows).render(style: style)
    }

    static func installsTable(_ installations: [Installation], defaultID: String?, style: Style) -> String {
        let rows = installations.map { installation -> [String] in
            [
                installation.id == defaultID ? style.green("*") : " ",
                installation.id,
                installation.flavor.rawValue,
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

    static func updateState(_ state: UpdateState, style: Style) -> String {
        switch state {
        case .upToDate: style.dim("up to date")
        case .available(let release): style.green("→ \(release.version)")
        case .pinned: style.yellow("pinned, skipped")
        case .noCompatibleRelease: style.dim("no Forever build")
        case .failed(let message): style.red("failed: \(message)")
        }
    }
}
