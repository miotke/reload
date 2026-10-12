import AddonKit
import ArgumentParser
import Foundation

struct ListCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List managed add-ons with version, source, channel and pin state.",
        aliases: ["ls"]
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Also list folders no managed add-on owns.")
    var unmanaged = false

    @Flag(help: "Only list add-ons whose folders are missing.")
    var missing = false

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installation()
        let statuses = Self.filter(try await context.manager.addons(in: installation), unmanaged: unmanaged, missing: missing)
        let games = await Self.games(statuses, in: installation, manager: context.manager)

        if context.json {
            try context.emit(Output(installation: installation, addons: statuses.map { AddonStatusJSON($0, availableFlavors: games[$0.id]) }))
            return
        }
        guard !statuses.isEmpty else {
            context.say(missing ? "No add-ons have missing folders." : "No add-ons installed. Try `addonctl search <words>`.")
            return
        }
        context.print(Format.listTable(statuses, flavor: installation.flavor, games: games, style: context.style))
        let managedCount = statuses.filter { if case .managed = $0 { true } else { false } }.count
        context.detail("\(managedCount) managed in \(installation.addonsDirectory.path(percentEncoded: false))")
    }

    /// Available flavors by `AddonStatus.id`: stored per repo for managed add-ons (falling back
    /// to their folders' TOCs), read from the TOCs on disk for unmanaged folders.
    static func games(_ statuses: [AddonStatus], in installation: Installation, manager: AddonManager) async -> [String: Set<Flavor>] {
        let stored = await manager.availableFlavors(for: statuses.compactMap { if case .managed(let addon, _) = $0 { addon.id } else { nil } })
        var out: [String: Set<Flavor>] = [:]
        for status in statuses {
            let folders: [String]
            switch status {
            case .managed(let addon, _):
                if let flavors = stored[addon.id] {
                    out[status.id] = flavors
                    continue
                }
                folders = addon.folders
            case .unmanaged(let unmanaged):
                folders = unmanaged.folders
            }
            let urls = folders.map { installation.addonsDirectory.appending(path: $0, directoryHint: .isDirectory) }
            let found = ZipInspector.availableFlavors(addonFolders: urls)
            if !found.isEmpty { out[status.id] = found }
        }
        return out
    }

    static func filter(_ statuses: [AddonStatus], unmanaged: Bool, missing: Bool) -> [AddonStatus] {
        statuses.filter { status in
            switch status {
            case .managed(_, let missingFolders): !missing || !missingFolders.isEmpty
            case .unmanaged: unmanaged && !missing
            }
        }
    }

    struct Output: Encodable {
        var installation: Installation
        var addons: [AddonStatusJSON]
    }
}

/// Shared by `pin` and `unpin`.
enum PinAction {
    static func run(_ inputs: [String], pinned: Bool, context: CLIContext) async throws {
        let installation = try await context.installation()
        var changed: [InstalledAddon] = []
        for input in inputs {
            let ref = try await context.ref(for: input, in: installation)
            try await context.manager.setPinned(pinned, for: ref, in: installation)
            if let addon = try await context.installedAddon(ref, in: installation) {
                changed.append(addon)
                context.say("\(pinned ? "Pinned" : "Unpinned") \(addon.name) \(addon.version)")
            }
        }
        if context.json { try context.emit(Output(installation: installation.id, addons: changed)) }
    }

    struct Output: Encodable {
        var installation: String
        var addons: [InstalledAddon]
    }
}

struct PinCommand: ContextCommand {
    static let configuration = CommandConfiguration(commandName: "pin", abstract: "Pin add-ons so `update` skips them.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Installed add-ons.", completion: .installedAddons)
    var refs: [String]

    func validate() throws {
        guard !refs.isEmpty else { throw ValidationError("Name at least one add-on.") }
    }

    func run(_ context: CLIContext) async throws {
        try await PinAction.run(refs, pinned: true, context: context)
    }
}

struct UnpinCommand: ContextCommand {
    static let configuration = CommandConfiguration(commandName: "unpin", abstract: "Unpin add-ons so `update` updates them again.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Installed add-ons.", completion: .installedAddons)
    var refs: [String]

    func validate() throws {
        guard !refs.isEmpty else { throw ValidationError("Name at least one add-on.") }
    }

    func run(_ context: CLIContext) async throws {
        try await PinAction.run(refs, pinned: false, context: context)
    }
}

struct ChannelCommand: ContextCommand {
    static let configuration = CommandConfiguration(commandName: "channel", abstract: "Set an add-on's release channel.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Installed add-on.", completion: .installedAddons)
    var ref: String

    @Argument(help: "stable or prerelease.")
    var channel: ChannelArgument

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installation()
        let addonRef = try await context.ref(for: ref, in: installation)
        try await context.manager.setChannel(channel.channel, for: addonRef, in: installation)
        let addon = try await context.installedAddon(addonRef, in: installation)
        if context.json {
            try context.emit(PinAction.Output(installation: installation.id, addons: addon.map { [$0] } ?? []))
        } else {
            context.say("\(addon?.name ?? Format.ref(addonRef)) now follows the \(channel.rawValue) channel. Run `addonctl update` to apply.")
        }
    }
}
