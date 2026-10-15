import AddonKit
import Foundation

/// What `install`, `remove`, `list` and `doctor` say about required add-ons
/// (docs/features/dependencies.md#in-the-cli). The core finds them; this only words and asks.
enum DependencyOffer {
    /// After an install: offers each missing dependency's suggested add-on (`[Y/n]`, or
    /// accepted by `--yes`), installs the accepted ones and checks those in turn, a few rounds
    /// deep. With `--no-deps`, or with no terminal and no `--yes`, nothing is offered. Warns
    /// about what's still missing and returns it, with how many extra installs were tried.
    static func run(
        after outcome: inout BatchInstaller.Outcome, noDeps: Bool, force: Bool, context: CLIContext, installation: Installation
    ) async throws -> (missing: [MissingDependency], attempted: Int) {
        let manager = context.manager
        let channel = context.config.load().defaultChannel ?? .stable
        let offers = !noDeps && (context.yes || context.interactive)
        var asked = Set<String>()
        var checking = outcome.installed.map(\.id)
        var attempted = 0
        for _ in 0..<3 where offers && !checking.isEmpty {
            let names = await Self.names(context, installation)
            var accepted: [BatchInstaller.Request] = []
            for dependency in await gather(checking, manager: manager, installation: installation) {
                guard asked.insert(dependency.id).inserted, let candidate = dependency.suggested,
                      !accepted.contains(where: { $0.ref == candidate.ref }) else { continue }
                if try context.confirm(question(dependency, candidate: candidate, names: names), action: "install", defaultYes: true) {
                    accepted.append(BatchInstaller.Request(ref: candidate.ref, channel: channel, version: nil, pin: false))
                }
            }
            guard !accepted.isEmpty else { break }
            attempted += accepted.count
            let more = await BatchInstaller.run(accepted, force: force, context: context, installation: installation)
            outcome.installed += more.installed
            outcome.failures += more.failures
            checking = more.installed.map(\.id)
        }
        let missing = await gather(outcome.installed.map(\.id), manager: manager, installation: installation)
        if !missing.isEmpty {
            let names = await Self.names(context, installation)
            for dependency in missing { context.warn(warning(dependency, names: names)) }
        }
        return (missing, attempted)
    }

    /// The missing dependencies of `refs`, one entry per folder.
    static func gather(_ refs: [AddonRef], manager: AddonManager, installation: Installation) async -> [MissingDependency] {
        var merged: [MissingDependency] = []
        for ref in refs {
            for dependency in await manager.missingDependencies(of: ref, in: installation) {
                if let index = merged.firstIndex(where: { $0.id == dependency.id }) {
                    merged[index].requiredBy += dependency.requiredBy.filter { !merged[index].requiredBy.contains($0) }
                } else {
                    merged.append(dependency)
                }
            }
        }
        return merged
    }

    /// Installed add-ons' names by ref.
    static func names(_ context: CLIContext, _ installation: Installation) async -> [AddonRef: String] {
        let installed = (try? await context.manager.installedAddons(in: installation)) ?? []
        return Dictionary(installed.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Wording

    /// "LittleWigs needs BigWigs", "LittleWigs and Capping need BigWigs".
    static func needs(_ dependency: MissingDependency, names: [AddonRef: String]) -> String {
        let who = dependency.requiredBy.map { names[$0] ?? Format.ref($0) }
        return "\(list(who)) \(who.count == 1 ? "needs" : "need") \(dependency.folder)"
    }

    /// "LittleWigs needs BigWigs. Install BigWigs (BigWigsMods/BigWigs)?"
    static func question(_ dependency: MissingDependency, candidate: DependencyCandidate, names: [AddonRef: String]) -> String {
        "\(needs(dependency, names: names)). Install \(candidate.name) (\(Format.ref(candidate.ref)))?"
    }

    /// What to do about a dependency that's still missing: the suggested install, the
    /// candidates to choose from, or a search.
    static func warning(_ dependency: MissingDependency, names: [AddonRef: String]) -> String {
        let start = "\(needs(dependency, names: names)), which isn't installed"
        if let suggested = dependency.suggested {
            return "\(start); install it with `reload install \(Format.ref(suggested.ref))`."
        }
        if !dependency.candidates.isEmpty {
            let options = dependency.candidates.map { "\(Format.ref($0.ref)) (\($0.reason))" }
            return "\(start). It may come from \(options.joined(separator: ", "))."
        }
        return "\(start). Search for it with `reload search \(dependency.folder)`."
    }

    /// "LittleWigs needs BigWigs and will stop loading." for each removed add-on with
    /// dependents that aren't being removed too.
    static func removalWarnings(_ dependents: [(removed: InstalledAddon, dependents: [InstalledAddon])]) -> [String] {
        dependents.compactMap { entry in
            guard !entry.dependents.isEmpty else { return nil }
            let names = entry.dependents.map(\.name)
            let verb = names.count == 1 ? "needs" : "need"
            return "\(list(names)) \(verb) \(entry.removed.name) and will stop loading."
        }
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

/// A `MissingDependency` in `--json` output.
struct MissingDependencyJSON: Encodable, Equatable {
    var folder: String
    var requiredBy: [AddonRef]
    var candidates: [Candidate]
    var suggested: Candidate?

    struct Candidate: Encodable, Equatable {
        var ref: AddonRef
        var name: String
        var reason: String

        init(_ candidate: DependencyCandidate) {
            ref = candidate.ref
            name = candidate.name
            reason = candidate.reason
        }
    }

    init(_ dependency: MissingDependency) {
        folder = dependency.folder
        requiredBy = dependency.requiredBy
        candidates = dependency.candidates.map(Candidate.init)
        suggested = dependency.suggested.map(Candidate.init)
    }
}
