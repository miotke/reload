import AddonKit
import ArgumentParser
import Foundation

struct SourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "List add-on sources, or turn one on or off for search and browse.",
        discussion: """
            Sources: github, wowinterface, tukui. A source that's off adds no search results and downloads no listing. \
            Add-ons already installed from it stay installed and keep getting update checks. Shared with the app's \
            Settings ▸ Sources.
            """,
        subcommands: [List.self, Enable.self, Disable.self],
        defaultSubcommand: List.self
    )

    struct SourceJSON: Encodable, Equatable {
        var source: String
        var name: String
        var enabled: Bool
    }

    struct Output: Encodable, Equatable {
        var sources: [SourceJSON]
    }

    static func output(_ settings: [SourceSetting]) -> Output {
        Output(sources: settings.map { SourceJSON(source: $0.source.rawValue, name: $0.source.displayName, enabled: $0.isEnabled) })
    }

    static func print(_ settings: [SourceSetting], _ context: CLIContext) throws {
        if context.json {
            try context.emit(output(settings))
            return
        }
        let rows = settings.map { setting in
            [setting.source.rawValue, setting.source.displayName, setting.isEnabled ? "on" : context.style.dim("off")]
        }
        context.print(Table(headers: ["SOURCE", "NAME", "SEARCH"], rows: rows).render(style: context.style))
    }

    static func parse(_ value: String) throws -> SourceID {
        guard let source = SourceID(rawValue: value.lowercased()) else {
            throw CLIError.usage("Unknown source \(value). Use one of: \(SourceID.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return source
    }

    struct List: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Show each source and whether it's on.")

        @OptionGroup var global: GlobalOptions

        func run(_ context: CLIContext) async throws {
            try SourcesCommand.print(await context.manager.sources(), context)
        }
    }

    struct Enable: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "enable", abstract: "Show a source's add-ons in search and browse.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "github, wowinterface or tukui.") var source: String

        func run(_ context: CLIContext) async throws {
            try await context.manager.setSource(SourcesCommand.parse(source), enabled: true)
            try SourcesCommand.print(await context.manager.sources(), context)
        }
    }

    struct Disable: ContextCommand {
        static let configuration = CommandConfiguration(
            commandName: "disable", abstract: "Hide a source's add-ons from search and browse; installed ones keep updating.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "github, wowinterface or tukui.") var source: String

        func run(_ context: CLIContext) async throws {
            try await context.manager.setSource(SourcesCommand.parse(source), enabled: false)
            try SourcesCommand.print(await context.manager.sources(), context)
        }
    }
}
