import AddonKit
import ArgumentParser
import Foundation

struct SearchCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search for add-ons that work on Forever.",
        discussion: "Waits for Forever verification of the top results before printing.",
        aliases: ["s"]
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Words to search for.")
    var query: [String]

    @Flag(help: "Also run a live GitHub search (uses API quota).")
    var github = false

    @Flag(help: "Include add-ons verified not to support Forever.")
    var all = false

    @Option(help: "Maximum number of results.")
    var limit = 20

    func validate() throws {
        guard limit > 0 else { throw ValidationError("--limit must be at least 1.") }
        guard !query.joined().trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError("Give some words to search for.") }
    }

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installationOrPlaceholder()
        let text = query.joined(separator: " ")
        let searchQuery = SearchQuery(text: text, flavor: installation.flavor, foreverOnly: !all, includeLiveGitHub: github)

        let spinner = Spinner(enabled: context.showsProgress)
        spinner.start("Searching for \"\(text)\" and checking Forever support…")
        var latest: [SearchResult] = []
        for await results in context.manager.search(searchQuery, in: installation) {
            latest = results
        }
        spinner.stop()

        let results = Self.filter(latest, all: all, limit: limit)
        if context.json {
            try context.emit(Output(query: text, results: results.map(SearchResultJSON.init)))
            return
        }
        guard !results.isEmpty else {
            context.print("No add-ons found for \"\(text)\".\(github ? "" : " Try --github to search GitHub too.")")
            return
        }
        context.print(Format.searchTable(results, style: context.style))
        if latest.count > results.count, !all {
            context.detail("\(latest.count - results.count) more result(s) hidden; use --limit or --all.")
        }
    }

    /// Drops results verified unsupported unless `all`, then applies `limit`.
    static func filter(_ results: [SearchResult], all: Bool, limit: Int) -> [SearchResult] {
        let visible = all ? results : results.filter {
            switch $0.support {
            case .unsupported, .noReleases: false
            default: true
            }
        }
        return Array(visible.prefix(limit))
    }

    struct Output: Encodable {
        var query: String
        var results: [SearchResultJSON]
    }
}
