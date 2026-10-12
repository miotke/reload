import AddonKit
import ArgumentParser
import Foundation

struct SearchCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search for add-ons that work on Forever.",
        discussion: """
            Searches the local catalogue. GitHub is asked only when fewer than 3 add-ons match, \
            or with --github. The GAMES column shows which games the latest release ships builds \
            for (R Retail, F Forever, C Classic). Rows not checked yet are checked before printing, \
            like the app does for rows on screen (quota-free); — means unknown (no release.json).
            """,
        aliases: ["s"]
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Words to search for.")
    var query: [String]

    @Flag(help: "Also run a deeper live GitHub search (uses search API quota).")
    var github = false

    @Flag(help: "Include add-ons with no build for this installation's game family (classic-only ones on Forever).")
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
        let searchQuery = SearchQuery(text: text, flavor: installation.flavor, hideIncompatible: !all, includeLiveGitHub: github)

        let spinner = Spinner(enabled: context.showsProgress)
        let updates = context.manager.searchUpdates(searchQuery, in: installation, installed: installed)
        var (latest, searchedGitHub) = await Self.collect(updates) { spinner.start("Searching GitHub…") }
        spinner.stop()
        if searchedGitHub, !github {
            context.note("Few local matches, so GitHub was searched too.")
        }

        let checkSpinner = Spinner(enabled: context.showsProgress)
        latest = await Self.checkGames(latest, flavor: installation.flavor, all: all, limit: limit, manager: context.manager, installation: installation) {
            checkSpinner.start("Checking games…")
        }
        checkSpinner.stop()
        let results = Self.filter(latest, flavor: installation.flavor, all: all, limit: limit)
        if context.json {
            try context.emit(Output(query: text, searchedGitHub: searchedGitHub, results: results.map(SearchResultJSON.init)))
            return
        }
        guard !results.isEmpty else {
            context.print("No add-ons found for \"\(text)\".\(github ? "" : " Try --github to search GitHub more widely.")")
            return
        }
        context.print(Format.searchTable(results, flavor: installation.flavor, style: context.style))
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

    /// Checks the rows about to be printed whose games aren't known, the way the app checks
    /// rows on screen (`checkVisible`: quota-free, at most 20 per call). A check can reveal a
    /// row to hide, letting an unchecked one move up, so this repeats a few times.
    static func checkGames(
        _ results: [SearchResult], flavor: Flavor, all: Bool, limit: Int,
        manager: any AddonManaging, installation: Installation, onStart: () -> Void = {}
    ) async -> [SearchResult] {
        var results = results
        var started = false
        for _ in 0..<(limit / 20 + 2) {
            let shown = filter(results, flavor: flavor, all: all, limit: limit)
            let unchecked = shown.filter { $0.availableFlavors == nil }.map(\.id)
            guard !unchecked.isEmpty else { break }
            if !started { onStart(); started = true }
            let targets = BrowseFilter.visibleCheckTargets(unchecked) { _ in false }
            guard !(await manager.checkVisible(targets, in: installation)).isEmpty else { break }
            let stored = await manager.storedAvailability(for: targets, in: installation)
            results = results.map { result in
                guard let answer = stored[result.id] else { return result }
                var result = result
                if let support = answer.support { result.support = support }
                if let flavors = answer.availableFlavors { result.availableFlavors = flavors }
                return result
            }
        }
        return results
    }

    /// Drops results with no build for the installation's family unless `all`
    /// (`Flavor.hidesAsIncompatible`; installed ones stay), then applies `limit`.
    static func filter(_ results: [SearchResult], flavor: Flavor, all: Bool, limit: Int) -> [SearchResult] {
        let visible = all ? results : results.filter {
            $0.installed != nil || !flavor.hidesAsIncompatible(families: $0.families, support: $0.support)
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
