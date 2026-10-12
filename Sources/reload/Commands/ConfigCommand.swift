import AddonKit
import ArgumentParser
import Foundation

extension ConfigKey: ExpressibleByArgument {
    static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and change settings: github-token, default-channel, default-install.",
        subcommands: [Get.self, SetValue.self, Unset.self]
    )

    struct Output: Encodable {
        var key: String
        var value: String?
    }

    static func service(_ context: CLIContext) -> ConfigService {
        ConfigService(store: context.config, keychain: context.keychain, environment: context.environment)
    }

    struct Get: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "get", abstract: "Print a setting (the token is masked).")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "github-token, default-channel or default-install.")
        var key: ConfigKey

        func run(_ context: CLIContext) async throws {
            let value = ConfigCommand.service(context).get(key)
            if context.json {
                try context.emit(Output(key: key.rawValue, value: value))
            } else {
                context.print(value ?? context.style.dim("(not set)"))
            }
        }
    }

    struct SetValue: ContextCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Change a setting.",
            discussion: "github-token is read from stdin so it never lands in shell history: `reload config set github-token` then paste, or pipe it in."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "github-token, default-channel or default-install.")
        var key: ConfigKey

        @Argument(help: "The value (not accepted for github-token).")
        var value: String?

        func validate() throws {
            if key == .githubToken, value != nil {
                throw ValidationError("github-token is read from stdin, not the command line, so it isn't saved in shell history.")
            }
            if key != .githubToken, value == nil {
                throw ValidationError("Give a value for \(key.rawValue).")
            }
        }

        func run(_ context: CLIContext) async throws {
            let service = ConfigCommand.service(context)
            switch key {
            case .githubToken:
                let secret = Prompter.readSecret(prompt: "GitHub token: ", stdinIsTTY: context.console.stdinIsTTY) ?? ""
                try service.set(.githubToken, to: secret)
            case .defaultInstall:
                let installation = try await DefaultInstall.resolve(value ?? "", context: context)
                try service.set(.defaultInstall, to: installation.id)
            case .defaultChannel:
                try service.set(.defaultChannel, to: value ?? "")
            }
            if context.json {
                try context.emit(Output(key: key.rawValue, value: service.get(key)))
            } else {
                context.say("Set \(key.rawValue) to \(service.get(key) ?? "")")
            }
        }
    }

    struct Unset: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "unset", abstract: "Remove a setting.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "github-token, default-channel or default-install.")
        var key: ConfigKey

        func run(_ context: CLIContext) async throws {
            try ConfigCommand.service(context).unset(key)
            if context.json {
                try context.emit(Output(key: key.rawValue, value: nil))
            } else {
                context.say("Unset \(key.rawValue).")
            }
        }
    }
}
