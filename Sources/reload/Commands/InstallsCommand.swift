import AddonKit
import ArgumentParser
import Foundation

struct InstallsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "installs",
        abstract: "List WoW installations and choose the default.",
        subcommands: [List.self, Add.self, Remove.self, Default.self],
        defaultSubcommand: List.self
    )

    struct Output: Encodable {
        var defaultInstall: String?
        var installations: [Installation]
    }

    struct List: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List installations; * marks the default.")

        @OptionGroup var global: GlobalOptions

        func run(_ context: CLIContext) async throws {
            let installations = try await context.manager.detectInstallations()
            let defaultID = Self.effectiveDefault(installations: installations, configured: context.config.load().defaultInstall)
            if context.json {
                try context.emit(Output(defaultInstall: defaultID, installations: installations))
                return
            }
            guard !installations.isEmpty else {
                context.print("No installations found. Add one with `reload installs add <path>`.")
                return
            }
            context.print(Format.installsTable(installations, defaultID: defaultID, style: context.style))
        }

        /// The configured default if it exists, else the only install.
        static func effectiveDefault(installations: [Installation], configured: String?) -> String? {
            if let configured, installations.contains(where: { $0.id == configured }) { return configured }
            return installations.count == 1 ? installations[0].id : nil
        }
    }

    struct Add: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Add an installation by path.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "The flavor folder (e.g. …/World of Warcraft/_classic_beta_), its Interface/AddOns, or the World of Warcraft folder.", completion: .directory)
        var path: String

        func run(_ context: CLIContext) async throws {
            let url = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            let installation = try await context.manager.addInstallation(at: url)
            if context.json {
                try context.emit(Output(defaultInstall: context.config.load().defaultInstall, installations: [installation]))
            } else {
                context.say("Added \(installation.flavor.displayName) installation \(installation.id) at \(installation.root.path(percentEncoded: false))")
            }
        }
    }

    struct Remove: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Forget an installation (its add-ons stay on disk).", aliases: ["rm"])

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Installation id.")
        var id: String

        func run(_ context: CLIContext) async throws {
            let installations = try await context.manager.installations()
            guard let installation = InstallationSelection.match(id: id, in: installations) else { throw CLIError.installationNotFound(id) }
            try await context.manager.removeInstallation(installation)
            if context.config.load().defaultInstall == installation.id {
                try context.config.update { $0.defaultInstall = nil }
            }
            if context.json {
                try context.emit(Output(defaultInstall: context.config.load().defaultInstall, installations: try await context.manager.installations()))
            } else {
                context.say("Forgot installation \(installation.id). Its add-ons were left in place.")
            }
        }
    }

    struct Default: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "default", abstract: "Set the installation used when --install isn't given.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Installation id or path.")
        var id: String

        func run(_ context: CLIContext) async throws {
            let installation = try await DefaultInstall.resolve(id, context: context)
            try context.config.update { $0.defaultInstall = installation.id }
            if context.json {
                try context.emit(Output(defaultInstall: installation.id, installations: try await context.manager.installations()))
            } else {
                context.say("Default installation is now \(installation.id) (\(installation.root.path(percentEncoded: false))).")
            }
        }
    }
}

/// Validates a `default-install` value (id, id prefix or path) against known installations.
enum DefaultInstall {
    static func resolve(_ value: String, context: CLIContext) async throws -> Installation {
        let installations = try await context.manager.installations()
        if let match = InstallationSelection.match(id: value, in: installations) { return match }
        if InstallationSelection.looksLikePath(value) {
            let url = URL(filePath: (value as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            return try await context.manager.addInstallation(at: url)
        }
        throw CLIError.installationNotFound(value)
    }
}
