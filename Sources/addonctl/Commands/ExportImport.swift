import AddonKit
import ArgumentParser
import Foundation

struct ExportCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write the add-on list as addons.json (stdout unless --output)."
    )

    @OptionGroup var global: GlobalOptions

    @Option(name: [.short, .long], help: "File to write.", completion: .file(extensions: ["json"]))
    var output: String?

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installation()
        let file = AddonsFile(installed: try await context.manager.installedAddons(in: installation))
        let data = try file.encoded()

        guard let output else {
            // The export is itself a schema-versioned JSON document, so --json prints it as is.
            context.console.out(String(decoding: data, as: UTF8.self))
            return
        }
        let url = URL(filePath: (output as NSString).expandingTildeInPath)
        try data.write(to: url, options: .atomic)
        if context.json {
            try context.emit(Output(path: url.path(percentEncoded: false), count: file.addons.count))
        } else {
            context.say("Exported \(file.addons.count) add-on\(file.addons.count == 1 ? "" : "s") to \(url.path(percentEncoded: false)).")
        }
    }

    struct Output: Encodable {
        var path: String
        var count: Int
    }
}

struct ImportCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Install everything listed in an addons.json file."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "An addons.json file written by `addonctl export` (- for stdin).", completion: .file(extensions: ["json"]))
    var file: String

    @Flag(help: "Overwrite folders that exist but aren't managed.")
    var force = false

    func run(_ context: CLIContext) async throws {
        let data = file == "-"
            ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(filePath: (file as NSString).expandingTildeInPath))
        let addonsFile = try AddonsFile.decode(data)
        let installation = try await context.installation()
        let installed = try await context.manager.installedAddons(in: installation)
        let plan = try Self.plan(addonsFile, installed: installed)

        // Already installed: just bring channel and pin state in line.
        for entry in plan.existing {
            if entry.addon.channel != entry.channel {
                try await context.manager.setChannel(entry.channel, for: entry.addon.id, in: installation)
            }
            if entry.addon.pinned != entry.pinned {
                try await context.manager.setPinned(entry.pinned, for: entry.addon.id, in: installation)
            }
            context.detail("\(entry.addon.name) is already installed")
        }

        let outcome = await BatchInstaller.run(plan.requests, force: force, context: context, installation: installation)
        if context.json {
            try context.emit(Output(
                installation: installation.id, installed: outcome.installed,
                alreadyInstalled: plan.existing.map(\.addon.id), failed: outcome.failedJSON
            ))
        } else {
            context.say("Imported \(outcome.installed.count) add-on\(outcome.installed.count == 1 ? "" : "s"); \(plan.existing.count) already installed.")
            context.noteIfGameRunning(changed: outcome.installed.count)
        }
        if let error = ExitStatus.batchError(failures: outcome.failures.map(\.error), total: plan.requests.count) { throw error }
    }

    struct Plan {
        var requests: [BatchInstaller.Request] = []
        var existing: [(addon: InstalledAddon, channel: Channel, pinned: Bool)] = []
    }

    /// Splits the file into installs and already-installed add-ons. Throws on an unparsable ref.
    static func plan(_ file: AddonsFile, installed: [InstalledAddon]) throws -> Plan {
        let parser = GitHubSource()
        var plan = Plan()
        for entry in file.addons {
            guard let ref = parser.parse(entry.ref) else { throw AddonError.invalidReference(entry.ref) }
            if let addon = installed.first(where: { $0.id == ref }) {
                plan.existing.append((addon, entry.channel, entry.pinned))
            } else {
                plan.requests.append(.init(ref: ref, channel: entry.channel, version: entry.pinned ? entry.version : nil, pin: entry.pinned, strictVersion: false))
            }
        }
        return plan
    }

    struct Output: Encodable {
        var installation: String
        var installed: [InstalledAddon]
        var alreadyInstalled: [AddonRef]
        var failed: [FailureJSON]
    }
}
