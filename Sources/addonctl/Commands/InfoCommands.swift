import AddonKit
import ArgumentParser
import Foundation

struct InfoCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show details about an add-on: latest Forever release, installed version and folders.",
        aliases: ["show"]
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The add-on.", completion: .installedAddons)
    var ref: String

    @Flag(help: "Include the release notes.")
    var changelog = false

    @Flag(help: "Look at prereleases too.")
    var prerelease = false

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installationOrPlaceholder()
        let addonRef = try await context.ref(for: ref, in: installation)
        let installed = try await context.installedAddon(addonRef, in: installation)
        let channel: Channel = prerelease ? .prerelease : (installed?.channel ?? context.config.load().defaultChannel ?? .stable)

        let spinner = Spinner(enabled: context.showsProgress)
        spinner.start("Looking up \(Format.ref(addonRef))…")
        let summary = await Self.catalogueInfo(for: addonRef, context: context, installation: installation)
        var release: ResolvedRelease?
        var releaseError: (any Error)?
        do {
            release = try await context.manager.resolve(addonRef, for: installation, channel: channel)
        } catch {
            releaseError = error
        }
        spinner.stop()

        let state: UpdateState? = installed.map { addon in
            if addon.pinned { return .pinned }
            if let release { return addon.isUpdate(release) ? .available(release) : .upToDate }
            if case AddonError.noCompatibleRelease? = releaseError { return .noCompatibleRelease }
            return .failed(releaseError.map(ExitStatus.message(for:)) ?? "unknown")
        }

        if context.json {
            try context.emit(Output(
                ref: addonRef, name: release?.name ?? installed?.name ?? summary?.name ?? addonRef.identifier,
                summary: summary?.summary, stars: summary?.stars, url: Self.webURL(addonRef),
                channel: channel, latest: release.map { ReleaseJSON($0, includeChangelog: changelog) },
                latestError: releaseError.map(ExitStatus.message(for:)),
                installed: installed, updateState: state.map(UpdateStateJSON.init)
            ))
            return
        }

        let style = context.style
        let name = release?.name ?? installed?.name ?? summary?.name ?? addonRef.identifier
        context.print(style.bold(name) + "  " + style.dim(Format.ref(addonRef)))
        if let text = summary?.summary { context.print(text) }
        var rows: [[String]] = []
        if let url = Self.webURL(addonRef) { rows.append(["Website", url.absoluteString]) }
        if let stars = summary?.stars { rows.append(["Stars", "\(stars)"]) }
        if let release {
            let pre = release.isPrerelease ? style.yellow(" (prerelease)") : ""
            rows.append(["Latest Forever", style.green(release.version) + pre + "  " + style.dim(Format.relative(release.publishedAt))])
            rows.append(["Asset", release.assetName])
        } else if let releaseError {
            rows.append(["Latest Forever", style.red(ExitStatus.message(for: releaseError))])
        }
        rows.append(["Channel", channel.rawValue])
        if let installed {
            var version = installed.version + "  " + style.dim("installed \(Format.relative(installed.installedAt))")
            if installed.pinned { version += style.yellow("  pinned") }
            rows.append(["Installed", version])
            if let state { rows.append(["Status", Format.updateState(state, style: style)]) }
            rows.append(["Folders", installed.folders.joined(separator: ", ")])
            if let previous = installed.previousRelease { rows.append(["Rollback to", previous.version]) }
        } else {
            rows.append(["Installed", style.dim("no")])
        }
        context.print(Table(headers: [], rows: rows.map { [style.dim($0[0]), $0[1]] }).render(style: style))
        if let release, !release.reasoning.isEmpty {
            context.print("")
            context.print(style.bold("Why this release:"))
            for line in release.reasoning { context.print("  • " + line) }
        }
        if changelog {
            let notes = release?.changelog ?? installed?.changelog
            context.print("")
            context.print(style.bold("Changelog:"))
            context.print(notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? style.dim("(none)"))
        }
    }

    static func webURL(_ ref: AddonRef) -> URL? {
        ref.source == .github ? URL(string: "https://github.com/\(ref.identifier)") : nil
    }

    /// Description and stars from the first (local) search emission, best effort.
    static func catalogueInfo(for ref: AddonRef, context: CLIContext, installation: Installation) async -> SearchResult? {
        let query = SearchQuery(text: ref.identifier.split(separator: "/").last.map(String.init) ?? ref.identifier, flavor: installation.flavor, foreverOnly: false)
        for await results in context.manager.search(query, in: installation) {
            return results.first { $0.id == ref }
        }
        return nil
    }

    struct Output: Encodable {
        var ref: AddonRef
        var name: String
        var summary: String?
        var stars: Int?
        var url: URL?
        var channel: Channel
        var latest: ReleaseJSON?
        var latestError: String?
        var installed: InstalledAddon?
        var updateState: UpdateStateJSON?
    }
}

struct ResolveCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve",
        abstract: "Dry run: show which release and asset would be installed, and why."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The add-on.", completion: .installedAddons)
    var ref: String

    @Flag(help: "Consider prereleases.")
    var prerelease = false

    func run(_ context: CLIContext) async throws {
        let installation = try await context.installationOrPlaceholder()
        let addonRef = try await context.ref(for: ref, in: installation)
        let channel: Channel = prerelease ? .prerelease : (context.config.load().defaultChannel ?? .stable)
        let release = try await context.manager.resolve(addonRef, for: installation, channel: channel)

        if context.json {
            try context.emit(Output(flavor: installation.flavor, channel: channel, release: ReleaseJSON(release)))
            return
        }
        let style = context.style
        context.print(style.bold(release.name) + "  " + style.dim(Format.ref(release.ref)))
        let rows = [
            ["Flavor", installation.flavor.rawValue],
            ["Channel", channel.rawValue],
            ["Version", style.green(release.version) + (release.isPrerelease ? style.yellow(" (prerelease)") : "")],
            ["Release ID", String(release.releaseID)],
            ["Published", release.publishedAt.formatted(.iso8601) + "  " + style.dim(Format.relative(release.publishedAt))],
            ["Asset", release.assetName],
            ["Download", release.downloadURL.absoluteString],
        ]
        context.print(Table(headers: [], rows: rows.map { [style.dim($0[0]), $0[1]] }).render(style: style))
        context.print("")
        context.print(style.bold("Reasoning:"))
        if release.reasoning.isEmpty { context.print(style.dim("  (none recorded)")) }
        for (index, line) in release.reasoning.enumerated() {
            context.print("  \(index + 1). \(line)")
        }
    }

    struct Output: Encodable {
        var flavor: Flavor
        var channel: Channel
        var release: ReleaseJSON
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
