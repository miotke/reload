import AddonKit
import ArgumentParser
import Foundation

struct RefreshCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Refresh the catalogue, update checks and Forever support verdicts.",
        discussion: """
            Does nothing if the last refresh was under 2 hours ago, unless --force. Checks go to \
            github.com and raw.githubusercontent.com, which don't count against the API quota; \
            add-ons without a release.json may still need an API call.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Refresh now, and ask for every installed add-on's latest release.")
    var force = false

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installationOrPlaceholder()
        let line = StatusLine(enabled: context.showsProgress)
        var summary = Summary()
        for await progress in context.manager.refresh(in: installation, force: force) {
            summary.record(progress)
            if progress.phase != .finished { line.show(Self.progressText(progress, style: context.errStyle)) }
        }
        line.clear()
        let lastRefresh = await context.manager.lastRefresh(in: installation)
        let installed = (try? await context.manager.installedAddons(in: installation)) ?? []
        let names = Dictionary(installed.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let updates = (summary.updates ?? [:]).sorted { $0.key.identifier.lowercased() < $1.key.identifier.lowercased() }

        if context.json {
            try context.emit(Output(
                installation: installation.id, skipped: summary.skipped, lastRefresh: lastRefresh,
                updates: updates.map { Output.Entry(ref: $0.key, name: names[$0.key], update: UpdateStateJSON($0.value)) }
            ))
            return
        }
        for text in Self.summaryLines(summary, lastRefresh: lastRefresh) { context.say(text) }
        let available = updates.compactMap { ref, state -> [String]? in
            guard case .available(let release) = state else { return nil }
            let addon = installed.first { $0.id == ref }
            return [names[ref] ?? Format.ref(ref), addon?.version ?? "?", context.style.green(release.version)]
        }
        if !available.isEmpty {
            context.print(Table(headers: ["UPDATE", "INSTALLED", "LATEST"], rows: available).render(style: context.style))
            context.say("Run `addonctl update` to install \(available.count == 1 ? "it" : "them").")
        }
    }

    /// What one refresh did, phase by phase.
    struct Summary {
        /// Last (completed, total) per phase.
        var phases: [RefreshProgress.Phase: (completed: Int, total: Int)] = [:]
        var updates: [AddonRef: UpdateState]?

        /// True when the refresh finished at once because the last one was recent.
        var skipped: Bool { phases.isEmpty }

        mutating func record(_ progress: RefreshProgress) {
            if progress.phase == .finished {
                updates = progress.updates
            } else {
                phases[progress.phase] = (progress.completed, progress.total)
            }
        }
    }

    static func summaryLines(_ summary: Summary, lastRefresh: Date?, now: Date = Date()) -> [String] {
        if summary.skipped {
            let when = lastRefresh.map { " \(Format.relative($0, now: now))" } ?? " recently"
            return ["Already refreshed\(when); use --force to refresh now."]
        }
        let updates = summary.updates ?? [:]
        let available = updates.values.filter { if case .available = $0 { true } else { false } }.count
        let failed = updates.values.filter { if case .failed = $0 { true } else { false } }.count
        var lines: [String] = []
        if summary.phases[.catalogue] != nil { lines.append("Catalogue: checked") }
        if let checked = summary.phases[.updates] {
            var text = "Updates: checked \(checked.total) installed add-on\(checked.total == 1 ? "" : "s"), \(available) available"
            if failed > 0 { text += ", \(failed) failed" }
            lines.append(text)
        }
        if let support = summary.phases[.support] {
            lines.append("Forever support: checked \(support.completed) of \(support.total) add-on\(support.total == 1 ? "" : "s")")
        }
        return lines
    }

    /// `[2/3] Checking Forever support…  12/200 ━━━━──────`
    static func progressText(_ progress: RefreshProgress, style: Style) -> String {
        let step = switch progress.phase {
        case .catalogue: 1
        case .updates: 2
        case .support, .finished: 3
        }
        var text = style.dim("[\(step)/3]") + " " + progress.message
        if progress.total > 1 {
            let fraction = Double(progress.completed) / Double(progress.total)
            text += "  \(progress.completed)/\(progress.total) " + ProgressBoard.bar(fraction, width: 16, style: style)
        }
        return text
    }

    struct Output: Encodable {
        struct Entry: Encodable {
            var ref: AddonRef
            var name: String?
            var update: UpdateStateJSON
        }
        var installation: String
        /// True when nothing ran because the last refresh was recent.
        var skipped: Bool
        var lastRefresh: Date?
        var updates: [Entry]
    }
}

/// One status line on stderr, redrawn in place. A no-op unless `enabled`.
struct StatusLine: Sendable {
    var enabled: Bool

    func show(_ text: String) {
        guard enabled else { return }
        // Cut to the terminal width so the line never wraps and leaves debris behind.
        let width = Console.columns() - 1
        let line = Style.width(text) > width ? String(Style.strip(text).prefix(width)) : text
        Console.write("\r\u{1B}[2K" + line, to: .standardError)
    }

    func clear() {
        guard enabled else { return }
        Console.write("\r\u{1B}[2K", to: .standardError)
    }
}
