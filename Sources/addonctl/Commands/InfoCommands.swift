import AddonKit
import ArgumentParser
import Foundation

struct InfoCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show details about an add-on: description, Forever support, latest version, installed version and folders.",
        discussion: """
            Uses the stored details, refreshed from github.com and raw.githubusercontent.com when \
            they're over a day old. With --prerelease (or for an add-on on the prerelease \
            channel) the newest prerelease is resolved too, which uses the API.
            """,
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
        let manager = context.manager

        let spinner = Spinner(enabled: context.showsProgress)
        spinner.start("Looking up \(Format.ref(addonRef))…")
        let entry = await manager.catalogueEntry(for: addonRef)
        var details: AddonDetails?
        var detailsError: (any Error)?
        do {
            details = try await manager.details(for: addonRef, in: installation)
        } catch {
            detailsError = error
        }
        let readmePath = await MetadataInfo.readmePath(for: addonRef, in: manager.database)
        // Stable answers come from the stored details; prereleases only the API knows.
        var release: ResolvedRelease?
        var releaseError: (any Error)?
        if channel == .prerelease {
            do {
                release = try await manager.resolve(addonRef, for: installation, channel: .prerelease)
            } catch {
                releaseError = error
            }
        }
        spinner.stop()

        let state: UpdateStateJSON? = installed.map { addon in
            if channel == .prerelease {
                return UpdateStateJSON(Self.prereleaseState(addon, release: release, error: releaseError))
            }
            return Self.stableState(addon, latestVersion: details?.latestVersion, support: details?.support ?? .unknown)
        }
        let name = details?.name ?? entry?.name ?? installed?.name ?? addonRef.identifier
        let summary = details?.summary ?? entry?.description
        let readme = Self.readmeDescription(path: readmePath, hasReadme: details?.readme != nil)
        let notes = release?.changelog ?? details?.latestChangelog ?? installed?.changelog

        if context.json {
            try context.emit(Output(
                ref: addonRef, name: name, summary: summary, stars: details?.stars, url: Self.webURL(addonRef),
                lastUpdated: details?.lastUpdated ?? entry?.lastUpdated,
                support: details.map { SupportJSON($0.support) },
                latestVersion: details?.latestVersion, latestPublishedAt: details?.latestPublishedAt,
                readmePath: readmePath?.nilIfEmpty, screenshots: details?.screenshots.count ?? 0,
                detailsFetchedAt: details?.fetchedAt, detailsError: detailsError.map(ExitStatus.message(for:)),
                channel: channel, latest: release.map { ReleaseJSON($0, includeChangelog: changelog) },
                latestError: releaseError.map(ExitStatus.message(for:)),
                changelog: changelog ? notes : nil,
                installed: installed, updateState: state
            ))
            return
        }

        let style = context.style
        context.print(style.bold(name) + "  " + style.dim(Format.ref(addonRef)))
        if let summary { context.print(summary) }
        var rows: [[String]] = []
        if let url = Self.webURL(addonRef) { rows.append(["Website", url.absoluteString]) }
        if let stars = details?.stars { rows.append(["Stars", "\(stars)"]) }
        if let updated = details?.lastUpdated ?? entry?.lastUpdated { rows.append(["Updated", Format.relative(updated)]) }
        if let details {
            rows.append(["Forever", Format.support(details.support, style: style)])
            if let version = details.latestVersion {
                let published = details.latestPublishedAt.map { "  " + style.dim(Format.relative($0)) } ?? ""
                rows.append(["Latest", style.green(version) + published])
            }
            rows.append(["README", readme])
            rows.append(["Screenshots", "\(details.screenshots.count)"])
        } else if let detailsError {
            rows.append(["Details", style.red(ExitStatus.message(for: detailsError))])
        }
        if let release {
            let pre = release.isPrerelease ? style.yellow(" (prerelease)") : ""
            rows.append(["Latest prerelease", style.green(release.version) + pre + "  " + style.dim(Format.relative(release.publishedAt))])
        } else if let releaseError {
            rows.append(["Latest prerelease", style.red(ExitStatus.message(for: releaseError))])
        }
        rows.append(["Channel", channel.rawValue])
        if let installed {
            var version = installed.version + "  " + style.dim("installed \(Format.relative(installed.installedAt))")
            if installed.pinned { version += style.yellow("  pinned") }
            rows.append(["Installed", version])
            if let state { rows.append(["Status", Self.describe(state, style: style)]) }
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
            context.print("")
            context.print(style.bold("Changelog:"))
            context.print(notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? style.dim("(none)"))
        }
    }

    static func webURL(_ ref: AddonRef) -> URL? {
        ref.source == .github ? URL(string: "https://github.com/\(ref.identifier)") : nil
    }

    /// The stable channel's state from stored details: an unchanged version is up to date,
    /// the same rule the core's update check uses for quota-free releases.
    static func stableState(_ addon: InstalledAddon, latestVersion: String?, support: SupportStatus) -> UpdateStateJSON {
        if addon.pinned { return UpdateStateJSON(.pinned) }
        guard let latestVersion else { return UpdateStateJSON(state: "unknown") }
        if latestVersion == addon.version { return UpdateStateJSON(.upToDate) }
        switch support {
        case .unsupported, .noReleases: return UpdateStateJSON(.noCompatibleRelease)
        default: return UpdateStateJSON(state: "available", version: latestVersion)
        }
    }

    static func prereleaseState(_ addon: InstalledAddon, release: ResolvedRelease?, error: (any Error)?) -> UpdateState {
        if addon.pinned { return .pinned }
        if let release { return addon.isUpdate(release) ? .available(release) : .upToDate }
        if case AddonError.noCompatibleRelease? = error { return .noCompatibleRelease }
        return .failed(error.map(ExitStatus.message(for:)) ?? "unknown")
    }

    static func describe(_ state: UpdateStateJSON, style: Style) -> String {
        switch state.state {
        case "upToDate": style.dim("up to date")
        case "available": style.green("→ \(state.version ?? "?")") + style.dim("  run `addonctl update`")
        case "pinned": style.yellow("pinned, skipped")
        case "noCompatibleRelease": style.dim("no Forever build")
        case "failed": style.red("failed: \(state.message ?? "")")
        default: style.yellow("unknown")
        }
    }

    /// `path` is nil when nobody has looked yet, and empty when the repo has no README.
    static func readmeDescription(path: String?, hasReadme: Bool) -> String {
        switch path {
        case let path? where !path.isEmpty: path
        case ""?: "none"
        default: hasReadme ? "yes" : "not fetched yet"
        }
    }

    struct Output: Encodable {
        var ref: AddonRef
        var name: String
        var summary: String?
        var stars: Int?
        var url: URL?
        var lastUpdated: Date?
        var support: SupportJSON?
        var latestVersion: String?
        var latestPublishedAt: Date?
        var readmePath: String?
        var screenshots: Int
        var detailsFetchedAt: Date?
        var detailsError: String?
        var channel: Channel
        /// The resolved prerelease, on the prerelease channel only.
        var latest: ReleaseJSON?
        var latestError: String?
        var changelog: String?
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
