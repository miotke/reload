import AddonKit
import ArgumentParser
import Foundation

@main
struct ReloadCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload",
        abstract: "Manage World of Warcraft Forever add-ons.",
        discussion: """
            <ref> can be owner/repo, a GitHub URL, github:owner/repo, or the name of an \
            installed or catalogued add-on.

            Exit codes: 0 ok, 1 error, 2 usage, 3 partial failure, 4 rate limited, \
            5 conflict/unmanaged folder (retry with --force), 10 outdated.
            """,
        subcommands: [
            SearchCommand.self, InfoCommand.self, InstallCommand.self, RemoveCommand.self,
            UpdateCommand.self, OutdatedCommand.self, ListCommand.self, PinCommand.self,
            UnpinCommand.self, ChannelCommand.self, RollbackCommand.self, AdoptCommand.self,
            ResolveCommand.self, InstallsCommand.self, ExportCommand.self, ImportCommand.self,
            RefreshCommand.self, ConfigCommand.self, CacheCommand.self, DoctorCommand.self,
        ]
    )

    /// Replaces ArgumentParser's `main` so errors map to docs/cli/commands.md exit codes and
    /// `--json` errors are printed as JSON.
    static func main() async {
        await run(arguments: Array(CommandLine.arguments.dropFirst()))
    }

    /// `@concurrent` matches the isolation of `run()` in ArgumentParser, so the parsed
    /// command isn't sent across isolation domains.
    @concurrent static func run(arguments: [String]) async -> Never {
        let json = arguments.prefix { $0 != "--" }.contains("--json")

        var command: any ParsableCommand
        do {
            command = try parseAsRoot(arguments)
        } catch {
            exitWithParserError(error, json: json)
        }

        do {
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as CleanExit {
            exit(withError: error)
        } catch where isParserError(error) {
            // e.g. the built-in help command, which reports through an error.
            exitWithParserError(error, json: json)
        } catch {
            report(error, json: json)
            Foundation.exit(ExitStatus.code(for: error))
        }
        Foundation.exit(ExitStatus.success)
    }

    /// Errors from ArgumentParser itself (not `ExitCode`/`ValidationError`, which commands throw).
    static func isParserError(_ error: any Error) -> Bool {
        guard !(error is ExitCode), !(error is ValidationError) else { return false }
        return String(reflecting: type(of: error)).hasPrefix("ArgumentParser.")
    }

    /// Help, --version and completion requests exit 0 through ArgumentParser; anything else
    /// is a usage error (exit 2).
    static func exitWithParserError(_ error: any Error, json: Bool) -> Never {
        if exitCode(for: error) == .success { exit(withError: error) }
        if json {
            Console.write(JSONOutput.error(CLIError.usage(message(for: error))) + "\n", to: .standardError)
        } else {
            Console.write(fullMessage(for: error) + "\n", to: .standardError)
        }
        Foundation.exit(ExitStatus.usage)
    }

    static func report(_ error: any Error, json: Bool) {
        // Plain exit codes (e.g. `outdated`) have already printed their output.
        if error is ExitCode { return }
        if json {
            Console.write(JSONOutput.error(error) + "\n", to: .standardError)
        } else {
            let console = Console.detect()
            let style = Style(enabled: Style.colorEnabled(
                isTTY: console.stderrIsTTY, noColorFlag: CommandLine.arguments.contains("--no-color"),
                json: false, environment: ProcessInfo.processInfo.environment))
            Console.write(style.red("error: ") + ExitStatus.message(for: error) + "\n", to: .standardError)
        }
    }
}
