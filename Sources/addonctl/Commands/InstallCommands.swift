import AddonKit
import ArgumentParser
import Foundation

// MARK: - install

struct InstallCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install one or more add-ons.",
        aliases: ["i", "add"]
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Add-ons: owner/repo, a GitHub URL, or a name.", completion: .installedAddons)
    var refs: [String]

    @Flag(help: "Use the prerelease channel.")
    var prerelease = false

    @Option(name: .customLong("version"), help: ArgumentHelp("Install this release tag and pin it.", valueName: "tag"))
    var version: String?

    @Flag(help: "Overwrite folders that exist but aren't managed.")
    var force = false

    func validate() throws {
        guard !refs.isEmpty else { throw ValidationError("Name at least one add-on to install.") }
    }

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installation()
        var requests: [BatchInstaller.Request] = []
        for input in refs {
            let ref = try await context.ref(for: input, in: installation)
            let existing = try await context.installedAddon(ref, in: installation)
            let channel: Channel = prerelease ? .prerelease : (existing?.channel ?? context.config.load().defaultChannel ?? .stable)
            requests.append(.init(ref: ref, channel: channel, version: version, pin: version != nil))
        }
        let outcome = await BatchInstaller.run(requests, force: force, context: context, installation: installation)
        if context.json {
            try context.emit(InstallOutput(installation: installation.id, installed: outcome.installed, failed: outcome.failedJSON))
        } else {
            context.say("Installed \(outcome.installed.count) add-on\(outcome.installed.count == 1 ? "" : "s").")
            context.noteIfGameRunning(changed: outcome.installed.count)
        }
        if let error = ExitStatus.batchError(failures: outcome.failures.map(\.error), total: requests.count) { throw error }
    }
}

struct InstallOutput: Encodable {
    var installation: String
    var installed: [InstalledAddon]
    var failed: [FailureJSON]
}

struct FailureJSON: Encodable {
    var ref: AddonRef
    var code: String
    var message: String
}

/// Installs a batch of refs one after another with progress rows. Shared by `install` and `import`.
enum BatchInstaller {
    struct Request: Sendable {
        var ref: AddonRef
        var channel: Channel
        /// Only install if the selected release has this tag.
        var version: String?
        var pin: Bool
        /// When `version` isn't the current release: fail (true) or warn and install the current one.
        var strictVersion = true
    }

    struct Outcome {
        var installed: [InstalledAddon] = []
        var failures: [(ref: AddonRef, error: any Error)] = []

        var failedJSON: [FailureJSON] {
            failures.map { FailureJSON(ref: $0.ref, code: ExitStatus.identifier(for: $0.error), message: ExitStatus.message(for: $0.error)) }
        }
    }

    static func run(_ requests: [Request], force: Bool, context: CLIContext, installation: Installation) async -> Outcome {
        let board = ProgressBoard(live: context.showsProgress, style: context.errStyle)
        for request in requests {
            board.add(key: request.ref.description, name: Format.ref(request.ref))
        }
        var outcome = Outcome()
        for request in requests {
            let key = request.ref.description
            do {
                let addon = try await install(request, force: force, context: context, installation: installation) { fraction in
                    board.update(key: key, fraction: fraction, status: "downloading")
                }
                board.update(key: key, fraction: 1, detail: addon.version, status: context.errStyle.green("done"))
                outcome.installed.append(addon)
                if !board.live {
                    context.say("Installed \(addon.name) \(addon.version) (\(addon.folders.joined(separator: ", ")))")
                }
            } catch {
                board.update(key: key, status: context.errStyle.red("failed"))
                outcome.failures.append((request.ref, error))
                context.itemError(Format.ref(request.ref), error, batchSize: requests.count)
            }
        }
        board.finish()
        return outcome
    }

    static func install(
        _ request: Request, force: Bool, context: CLIContext, installation: Installation,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledAddon {
        let manager = context.manager
        if let wanted = request.version {
            // AddonKit can only install the release the selector picks; accept the tag if it matches.
            let release = try await manager.resolve(request.ref, for: installation, channel: request.channel)
            if !Self.tagsMatch(release.version, wanted) {
                let problem = "\(Format.ref(request.ref)) \(wanted) isn't the current \(installation.flavor.displayName) release (\(release.version)); installing older releases isn't supported yet."
                guard !request.strictVersion else { throw CLIError.general(problem) }
                context.warn(problem + " Installing \(release.version) instead.")
            }
        }
        var addon = try await manager.install(request.ref, into: installation, channel: request.channel, force: force, progress: progress)
        if request.pin, !addon.pinned {
            try await manager.setPinned(true, for: request.ref, in: installation)
            addon.pinned = true
        }
        return addon
    }

    /// `v1.2` matches `1.2`; otherwise tags must be equal ignoring case.
    static func tagsMatch(_ a: String, _ b: String) -> Bool {
        func normalized(_ s: String) -> String {
            let lower = s.lowercased()
            return lower.hasPrefix("v") ? String(lower.dropFirst()) : lower
        }
        return normalized(a) == normalized(b)
    }
}

// MARK: - remove

struct RemoveCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Uninstall add-ons (their folders are moved to the Trash).",
        aliases: ["rm", "uninstall"]
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Installed add-ons to remove.", completion: .installedAddons)
    var refs: [String]

    func validate() throws {
        guard !refs.isEmpty else { throw ValidationError("Name at least one add-on to remove.") }
    }

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installation()
        var targets: [InstalledAddon] = []
        for input in refs {
            let ref = try await context.ref(for: input, in: installation)
            guard let addon = try await context.installedAddon(ref, in: installation) else { throw AddonError.notInstalled(ref) }
            if !targets.contains(where: { $0.id == ref }) { targets.append(addon) }
        }
        let names = targets.map(\.name).joined(separator: ", ")
        let folderCount = targets.reduce(0) { $0 + $1.folders.count }
        guard try context.confirm("Remove \(names) (\(folderCount) folder\(folderCount == 1 ? "" : "s"))? Folders go to the Trash.", action: "remove") else {
            throw CLIError.cancelled
        }

        var removed: [InstalledAddon] = []
        var failures: [(ref: AddonRef, error: any Error)] = []
        for addon in targets {
            do {
                try await context.manager.uninstall(addon.id, from: installation)
                removed.append(addon)
                context.say("Removed \(addon.name) (\(addon.folders.joined(separator: ", ")))")
            } catch {
                failures.append((addon.id, error))
                context.itemError(addon.name, error, batchSize: targets.count)
            }
        }
        if context.json {
            let failed = failures.map { FailureJSON(ref: $0.ref, code: ExitStatus.identifier(for: $0.error), message: ExitStatus.message(for: $0.error)) }
            try context.emit(RemoveOutput(installation: installation.id, removed: removed, failed: failed))
        } else {
            context.noteIfGameRunning(changed: removed.count)
        }
        if let error = ExitStatus.batchError(failures: failures.map(\.error), total: targets.count) { throw error }
    }

    struct RemoveOutput: Encodable {
        var installation: String
        var removed: [InstalledAddon]
        var failed: [FailureJSON]
    }
}

// MARK: - update

/// A failure reported by an `OperationEvent` or `UpdateState`, which only carry a message.
struct OperationFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }

    /// The core's own wording for a rate limit, without the full stop and retry time.
    static let rateLimitPrefix = AddonError.rateLimited(resetAt: nil).localizedDescription
        .trimmingCharacters(in: .punctuationCharacters)

    /// Recovers the typed error. The core's events carry no error value, so a rate limit is
    /// recognised by the stored API rate-limit state first and the core's message second.
    func typed(rateLimit: RateLimitState? = nil, now: Date = Date()) -> any Error {
        if let rateLimit, rateLimit.isExhausted(at: now) { return AddonError.rateLimited(resetAt: rateLimit.resetAt) }
        if message.hasPrefix(Self.rateLimitPrefix) { return AddonError.rateLimited(resetAt: nil) }
        return self
    }
}

struct UpdateCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update all add-ons, or the ones listed. Pinned add-ons are skipped.",
        discussion: """
            Checks every add-on first and downloads only real updates. Add-ons that ship a \
            release.json are checked on github.com, so an update that finds nothing new uses no \
            API quota.
            """,
        aliases: ["upgrade", "up"]
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Add-ons to update (default: all).", completion: .installedAddons)
    var refs: [String] = []

    @Flag(help: "Show what would change without installing anything.")
    var dryRun = false

    /// What to do with each add-on after a check.
    struct Plan {
        var install: [ResolvedRelease] = []
        var skipped: [SkippedJSON] = []
        var failed: [(ref: AddonRef, message: String)] = []
    }

    /// Only `.available` states are installed; everything else is reported as checked.
    static func plan(_ installed: [InstalledAddon], states: [AddonRef: UpdateState], flavor: Flavor) -> Plan {
        var plan = Plan()
        for addon in installed {
            switch states[addon.id] {
            case .available(let release)?: plan.install.append(release)
            case .upToDate?: plan.skipped.append(SkippedJSON(ref: addon.id, reason: "Up to date"))
            case .pinned?: plan.skipped.append(SkippedJSON(ref: addon.id, reason: "Pinned"))
            case .noCompatibleRelease?:
                plan.failed.append((addon.id, AddonError.noCompatibleRelease(addon.id, flavor).localizedDescription))
            case .failed(let message)?: plan.failed.append((addon.id, message))
            case nil: plan.failed.append((addon.id, "Not checked"))
            }
        }
        return plan
    }

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installation()
        var targets: [AddonRef] = []
        for input in refs {
            let ref = try await context.ref(for: input, in: installation)
            if !targets.contains(ref) { targets.append(ref) }
        }
        let installed = try await context.manager.installedAddons(in: installation)
        for ref in targets where !installed.contains(where: { $0.id == ref }) {
            throw AddonError.notInstalled(ref)
        }
        if dryRun {
            try await OutdatedCommand.report(context: context, installation: installation, only: targets, dryRun: true)
            return
        }
        guard !installed.isEmpty else {
            context.print("No add-ons installed.")
            if context.json { try context.emit(UpdateOutput(installation: installation.id, updated: [], skipped: [], failed: [])) }
            return
        }
        try await Self.perform(targets, installed: installed, context: context, installation: installation)
    }

    /// With no `targets`, checks everything once (always asking for the latest tags) and
    /// installs only the add-ons with an update. Named targets go through the core's
    /// per-add-on check-then-install.
    static func perform(_ targets: [AddonRef], installed: [InstalledAddon], context: CLIContext, installation: Installation) async throws {
        let manager = context.manager
        let byRef = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let board = ProgressBoard(live: context.showsProgress, style: context.errStyle)
        let style = context.errStyle
        var updated: [UpdatedJSON] = []
        var skipped: [SkippedJSON] = []
        var failures: [(ref: AddonRef, message: String)] = []
        var lines: [[String]] = []

        func name(_ ref: AddonRef) -> String { byRef[ref]?.name ?? Format.ref(ref) }
        func from(_ ref: AddonRef) -> String { byRef[ref]?.version ?? "?" }
        func skip(_ ref: AddonRef, _ reason: String) {
            skipped.append(SkippedJSON(ref: ref, reason: reason))
            let text = reason == "Pinned" ? "pinned, skipped" : reason.lowercased()
            board.update(key: ref.description, status: style.dim(text))
            if reason == "Pinned" || context.verbose {
                lines.append([name(ref), from(ref), context.style.dim(text)])
            }
        }
        func fail(_ ref: AddonRef, _ message: String) {
            failures.append((ref, message))
            board.update(key: ref.description, status: style.red("failed"))
            lines.append([name(ref), from(ref), context.style.red("failed: \(message)")])
        }

        var events: AsyncStream<OperationEvent>?
        if targets.isEmpty {
            for addon in installed {
                board.add(key: addon.id.description, name: addon.name, detail: addon.version, status: style.dim("checking"))
            }
            let states = try await manager.checkForUpdates(in: installation)
            let plan = Self.plan(installed, states: states, flavor: installation.flavor)
            for item in plan.skipped { skip(item.ref, item.reason) }
            for item in plan.failed { fail(item.ref, item.message) }
            // An empty list means "every add-on" to the core, which would check them all again.
            if !plan.install.isEmpty { events = manager.update(releases: plan.install, in: installation) }
        } else {
            events = manager.update(targets, in: installation)
        }

        if let events {
            for await event in events {
                switch event {
                case .queued(let ref):
                    board.add(key: ref.description, name: name(ref), detail: from(ref), status: style.dim("checking"))
                case .downloading(let ref, let progress):
                    board.update(key: ref.description, fraction: progress, detail: "\(from(ref)) → …", status: "downloading")
                case .installing(let ref):
                    board.update(key: ref.description, fraction: 1, status: "installing")
                case .done(let addon):
                    board.update(key: addon.id.description, fraction: 1, detail: "\(from(addon.id)) → \(addon.version)", status: style.green("done"))
                    updated.append(UpdatedJSON(ref: addon.id, from: from(addon.id), to: addon.version, addon: addon))
                    lines.append([addon.name, "\(from(addon.id)) → \(addon.version)", context.style.green("done")])
                case .skipped(let ref, let reason):
                    skip(ref, reason)
                case .failed(let ref, let message):
                    fail(ref, message)
                }
            }
        }
        board.finish()

        let rateLimit = failures.isEmpty ? nil : await manager.database.rateLimit("core")
        let typedFailures = failures.map { (ref: $0.ref, error: OperationFailure(message: $0.message).typed(rateLimit: rateLimit)) }
        if context.json {
            let failed = typedFailures.map { FailureJSON(ref: $0.ref, code: ExitStatus.identifier(for: $0.error), message: ExitStatus.message(for: $0.error)) }
            try context.emit(UpdateOutput(installation: installation.id, updated: updated, skipped: skipped, failed: failed))
        } else {
            if !board.live, !lines.isEmpty, !context.quiet {
                context.print(Table(headers: [], rows: lines).render(style: context.style))
            } else if board.live {
                for failure in typedFailures {
                    context.console.err(style.red("error: ") + "\(name(failure.ref)): " + ExitStatus.message(for: failure.error))
                }
            }
            if updated.isEmpty && failures.isEmpty {
                context.say("Everything is up to date.")
            } else if !updated.isEmpty {
                context.say("Updated \(updated.count) add-on\(updated.count == 1 ? "" : "s").")
            }
            context.noteIfGameRunning(changed: updated.count)
        }
        let attempted = updated.count + failures.count
        if let error = ExitStatus.batchError(failures: typedFailures.map(\.error), total: max(attempted, 1)) { throw error }
    }

    struct UpdatedJSON: Encodable {
        var ref: AddonRef
        var from: String
        var to: String
        var addon: InstalledAddon
    }

    struct SkippedJSON: Encodable, Equatable {
        var ref: AddonRef
        var reason: String
    }

    struct UpdateOutput: Encodable {
        var installation: String
        var updated: [UpdatedJSON]
        var skipped: [SkippedJSON]
        var failed: [FailureJSON]
    }
}

// MARK: - outdated

struct OutdatedCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "outdated",
        abstract: "List add-ons with updates available (exit code 10 if any)."
    )

    @OptionGroup var global: GlobalOptions

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installation()
        try await Self.report(context: context, installation: installation, only: [], dryRun: false)
    }

    /// Shared by `outdated` and `update --dry-run`. `only` limits the report to some refs.
    static func report(context: CLIContext, installation: Installation, only: [AddonRef], dryRun: Bool) async throws {
        let spinner = Spinner(enabled: context.showsProgress)
        spinner.start("Checking for updates…")
        let states = try await context.manager.checkForUpdates(in: installation)
        let installed = try await context.manager.installedAddons(in: installation)
        spinner.stop()

        let entries = installed
            .filter { only.isEmpty || only.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { (addon: $0, state: states[$0.id] ?? .failed("not checked")) }
        let outdated = entries.filter { if case .available = $0.state { true } else { false } }
        let failures = entries.compactMap { entry -> String? in
            if case .failed(let message) = entry.state { return "\(entry.addon.name): \(message)" }
            return nil
        }

        if context.json {
            try context.emit(OutdatedOutput(
                installation: installation.id, dryRun: dryRun ? true : nil,
                addons: entries.map { OutdatedOutput.Entry(ref: $0.addon.id, name: $0.addon.name, installed: $0.addon.version, update: UpdateStateJSON($0.state)) }
            ))
        } else {
            if outdated.isEmpty {
                context.say("Everything is up to date.")
            } else {
                context.print(Format.outdatedTable(outdated, style: context.style))
            }
            let pinned = entries.filter { $0.state == .pinned }
            if dryRun, !pinned.isEmpty {
                context.say(context.style.dim("Pinned, would skip: \(pinned.map(\.addon.name).joined(separator: ", "))"))
            }
            for failure in failures { context.warn(failure) }
            if dryRun, !outdated.isEmpty {
                context.say("Would update \(outdated.count) add-on\(outdated.count == 1 ? "" : "s"). Run without --dry-run to apply.")
            }
        }
        if !dryRun, !outdated.isEmpty { throw ExitCode(ExitStatus.outdated) }
    }

    struct OutdatedOutput: Encodable {
        struct Entry: Encodable {
            var ref: AddonRef
            var name: String
            var installed: String
            var update: UpdateStateJSON
        }
        var installation: String
        var dryRun: Bool?
        var addons: [Entry]
    }
}

// MARK: - rollback

struct RollbackCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Reinstall the previously installed version from the download cache (and pin it)."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The add-on.", completion: .installedAddons)
    var ref: String

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installation()
        let addonRef = try await context.ref(for: ref, in: installation)
        guard let addon = try await context.installedAddon(addonRef, in: installation) else { throw AddonError.notInstalled(addonRef) }
        guard let previous = addon.previousRelease else { throw AddonError.noRollbackAvailable(addonRef) }
        guard try context.confirm("Roll \(addon.name) back from \(addon.version) to \(previous.version)?", action: "rollback") else {
            throw CLIError.cancelled
        }
        try await context.manager.rollback(addonRef, in: installation)
        let current = try await context.installedAddon(addonRef, in: installation)
        if context.json {
            try context.emit(RollbackOutput(installation: installation.id, from: addon.version, addon: current))
        } else {
            context.say("Rolled \(addon.name) back to \(previous.version) and pinned it. Run `addonctl unpin \(ref)` to resume updates.")
            context.noteIfGameRunning(changed: 1)
        }
    }

    struct RollbackOutput: Encodable {
        var installation: String
        var from: String
        var addon: InstalledAddon?
    }
}

// MARK: - adopt

struct AdoptCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Start managing an unmanaged folder.",
        discussion: "With no arguments, walks through every unmanaged folder that has a suggested add-on. Adopting reinstalls the latest release over the folder."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Folder in Interface/AddOns.")
    var folder: String?

    @Argument(help: "The add-on that owns it.")
    var ref: String?

    func validate() throws {
        if (folder == nil) != (ref == nil) { throw ValidationError("Give both <folder> and <ref>, or neither.") }
    }

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installation()
        let statuses = try await context.manager.addons(in: installation)
        var candidates: [(folders: [String], ref: AddonRef)] = []

        if let folder, let ref {
            guard let match = statuses.first(where: {
                if case .unmanaged(let name, _, _) = $0 { name.caseInsensitiveCompare(folder) == .orderedSame } else { false }
            }), case .unmanaged(let name, _, _) = match else {
                throw CLIError.usage("\(folder) isn't an unmanaged folder in \(installation.addonsDirectory.path(percentEncoded: false)). See `addonctl list --unmanaged`.")
            }
            candidates = [([name], try await context.ref(for: ref, in: installation))]
        } else {
            for status in statuses {
                guard case .unmanaged(let name, _, let suggested?) = status else { continue }
                if let index = candidates.firstIndex(where: { $0.ref == suggested }) {
                    candidates[index].folders.append(name)
                } else {
                    candidates.append(([name], suggested))
                }
            }
            if candidates.isEmpty {
                context.print("No unmanaged folders with a suggested add-on. Use `addonctl adopt <folder> <ref>`.")
                if context.json { try context.emit(AdoptOutput(installation: installation.id, adopted: [], failed: [])) }
                return
            }
        }

        var adopted: [InstalledAddon] = []
        var failures: [(ref: AddonRef, error: any Error)] = []
        for candidate in candidates {
            let question = "Adopt \(candidate.folders.joined(separator: ", ")) as \(Format.ref(candidate.ref))? The latest release is installed over it."
            guard try context.confirm(question, action: "adopt") else { continue }
            do {
                let addon = try await context.manager.adopt(folder: candidate.folders[0], as: candidate.ref, in: installation)
                adopted.append(addon)
                context.say("Adopted \(addon.name) \(addon.version) (\(addon.folders.joined(separator: ", ")))")
            } catch {
                failures.append((candidate.ref, error))
                context.itemError(Format.ref(candidate.ref), error, batchSize: candidates.count)
            }
        }
        if context.json {
            let failed = failures.map { FailureJSON(ref: $0.ref, code: ExitStatus.identifier(for: $0.error), message: ExitStatus.message(for: $0.error)) }
            try context.emit(AdoptOutput(installation: installation.id, adopted: adopted, failed: failed))
        } else {
            context.noteIfGameRunning(changed: adopted.count)
        }
        if let error = ExitStatus.batchError(failures: failures.map(\.error), total: adopted.count + failures.count) { throw error }
    }

    struct AdoptOutput: Encodable {
        var installation: String
        var adopted: [InstalledAddon]
        var failed: [FailureJSON]
    }
}
