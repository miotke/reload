import AddonKit
import ArgumentParser
import Foundation

struct DoctorCommand: ContextCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check installations, store integrity, GitHub access and the token."
    )

    @OptionGroup var global: GlobalOptions

    struct Check: Encodable, Equatable {
        enum Level: String, Encodable { case ok, warning, error }
        var name: String
        var level: Level
        var message: String
    }

    struct Output: Encodable {
        var healthy: Bool
        var checks: [Check]
    }

    func run(_ context: CLIContext) async throws {
        let spinner = Spinner(enabled: context.showsProgress)
        spinner.start("Checking…")
        var checks: [Check] = []

        // Installations
        let installations = (try? await context.manager.detectInstallations()) ?? []
        if installations.isEmpty {
            checks.append(Check(name: "Installations", level: .error, message: "No WoW installation found. Add one with `addonctl installs add <path>`."))
        } else {
            let forever = installations.filter { $0.flavor == .forever }
            checks.append(Check(
                name: "Installations",
                level: forever.isEmpty ? .error : .ok,
                message: "\(installations.count) found, \(forever.count) Forever"
            ))
        }
        let configured = context.config.load().defaultInstall
        if let configured, !installations.contains(where: { $0.id == configured }) {
            checks.append(Check(name: "Default install", level: .warning, message: "default-install \(configured) no longer exists; run `addonctl config unset default-install`."))
        }

        for installation in installations {
            let label = "Install \(installation.id)"
            let path = installation.addonsDirectory.path(percentEncoded: false)
            guard FileManager.default.isReadableFile(atPath: path) else {
                checks.append(Check(name: label, level: .error, message: "\(path) isn't readable or doesn't exist"))
                continue
            }
            do {
                let statuses = try await context.manager.addons(in: installation)
                checks += Self.integrity(statuses, label: label)
            } catch {
                checks.append(Check(name: label, level: .error, message: "Store unreadable: \(ExitStatus.message(for: error))"))
            }
        }

        // GitHub
        let token = Self.tokenSource(context)
        checks.append(await Self.github(token: token.value))
        checks.append(token.value == nil
            ? Check(name: "GitHub token", level: .warning, message: "Not set (60 API calls/hour). Set one with `addonctl config set github-token`.")
            : Check(name: "GitHub token", level: .ok, message: "Set (\(token.source))"))

        checks.append(Check(name: "WoW", level: .ok, message: WoWProcess.isRunning() ? "Running (type /reload after changes)" : "Not running"))
        if CLIEnvironment.dataDirectory(context.environment) != nil {
            checks.append(Check(name: "Data", level: .warning, message: "Using \(CLIEnvironment.dataDirectoryVariable)=\(context.directories.applicationSupport.deletingLastPathComponent().path(percentEncoded: false))"))
        }
        spinner.stop()

        let healthy = !checks.contains { $0.level == .error }
        if context.json {
            try context.emit(Output(healthy: healthy, checks: checks))
        } else {
            let style = context.style
            let rows = checks.map { check -> [String] in
                let mark = switch check.level {
                case .ok: style.green("✓")
                case .warning: style.yellow("!")
                case .error: style.red("✗")
                }
                return [mark, check.name, check.message]
            }
            context.print(Table(headers: [], rows: rows).render(style: style))
        }
        if !healthy { throw ExitCode(ExitStatus.general) }
    }

    /// Records with missing folders and folders claimed by more than one add-on.
    static func integrity(_ statuses: [AddonStatus], label: String) -> [Check] {
        var checks: [Check] = []
        var owners: [String: [String]] = [:]
        var managed = 0
        var unmanaged = 0
        for status in statuses {
            switch status {
            case .managed(let addon, let missing):
                managed += 1
                for folder in addon.folders { owners[folder.lowercased(), default: []].append(addon.name) }
                if !missing.isEmpty {
                    checks.append(Check(name: label, level: .warning, message: "\(addon.name) is missing \(missing.joined(separator: ", ")); reinstall or remove it"))
                }
            case .unmanaged:
                unmanaged += 1
            }
        }
        for (folder, names) in owners.sorted(by: { $0.key < $1.key }) where names.count > 1 {
            checks.append(Check(name: label, level: .error, message: "\(folder) is claimed by \(names.joined(separator: " and "))"))
        }
        checks.insert(Check(name: label, level: .ok, message: "\(managed) managed, \(unmanaged) unmanaged"), at: 0)
        return checks
    }

    static func tokenSource(_ context: CLIContext) -> (value: String?, source: String) {
        for name in ["ADDONS_GITHUB_TOKEN", "GITHUB_TOKEN"] {
            if let value = context.environment[name], !value.isEmpty { return (value, "$\(name)") }
        }
        return (context.keychain.get(), "Keychain")
    }

    /// `GET /rate_limit` doesn't count against the limit.
    static func github(token: String?) async -> Check {
        var request = URLRequest(url: URL(string: "https://api.github.com/rate_limit")!, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 401 {
                return Check(name: "GitHub", level: .error, message: "Reachable, but the token was rejected (401)")
            }
            struct Body: Decodable {
                struct Rate: Decodable { var limit: Int; var remaining: Int; var reset: TimeInterval }
                var rate: Rate
            }
            let rate = try JSONDecoder().decode(Body.self, from: data).rate
            let reset = Date(timeIntervalSince1970: rate.reset)
            let level: Check.Level = rate.remaining == 0 ? .error : (rate.remaining < 10 ? .warning : .ok)
            return Check(name: "GitHub", level: level, message: "Reachable; \(rate.remaining)/\(rate.limit) API calls left, resets \(reset.formatted(.relative(presentation: .named)))")
        } catch {
            return Check(name: "GitHub", level: .error, message: "Unreachable: \(error.localizedDescription)")
        }
    }
}
