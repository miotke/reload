import AddonKit
import ArgumentParser
import Foundation

struct SearchCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search for add-ons that work on Forever.",
        discussion: """
            Searches the local catalogue. GitHub is asked only when fewer than 3 add-ons match, \
            or with --github. The FOREVER column shows stored verdicts; `addonctl refresh` and \
            `addonctl info` update them.
            """,
        aliases: ["s"]
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Words to search for.")
    var query: [String]

    @Flag(help: "Also run a deeper live GitHub search (uses search API quota).")
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
        let installed = (try? await context.manager.addons(in: installation)) ?? []
        let text = query.joined(separator: " ")
        let searchQuery = SearchQuery(text: text, flavor: installation.flavor, foreverOnly: !all, includeLiveGitHub: github)

        let spinner = Spinner(enabled: context.showsProgress)
        let updates = context.manager.searchUpdates(searchQuery, in: installation, installed: installed)
        let (latest, searchedGitHub) = await Self.collect(updates) { spinner.start("Searching GitHub…") }
        spinner.stop()
        if searchedGitHub, !github {
            context.note("Few local matches, so GitHub was searched too.")
        }

        let results = Self.filter(latest, all: all, limit: limit)
        if context.json {
            try context.emit(Output(query: text, searchedGitHub: searchedGitHub, results: results.map(SearchResultJSON.init)))
            return
        }
        guard !results.isEmpty else {
            context.print("No add-ons found for \"\(text)\".\(github ? "" : " Try --github to search GitHub more widely.")")
            return
        }
        context.print(Format.searchTable(results, style: context.style))
        if latest.count > results.count, !all {
            context.detail("\(latest.count - results.count) more result(s) hidden; use --limit or --all.")
        }
    }

    /// The last results, and whether GitHub live search ran. `onGitHub` is called once,
    /// when it starts.
    static func collect(_ updates: AsyncStream<SearchUpdate>, onGitHub: () -> Void = {}) async -> (results: [SearchResult], searchedGitHub: Bool) {
        var latest: [SearchResult] = []
        var searchedGitHub = false
        for await update in updates {
            latest = update.results
            if update.isSearchingGitHub, !searchedGitHub {
                searchedGitHub = true
                onGitHub()
            }
        }
        return (latest, searchedGitHub)
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
        /// True when GitHub live search ran (automatically or with `--github`).
        var searchedGitHub: Bool
        var results: [SearchResultJSON]
    }
}
