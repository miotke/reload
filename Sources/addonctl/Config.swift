import AddonKit
import Foundation

/// Non-secret CLI settings, stored at `<applicationSupport>/config.json`.
/// The GitHub token lives in the Keychain instead.
struct CLIConfig: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var defaultChannel: Channel?
    var defaultInstall: String?
}

/// Reads and writes `config.json`. Missing or unreadable files read as an empty config.
struct ConfigStore: Sendable {
    var url: URL

    init(directories: AppDirectories) {
        self.url = directories.applicationSupport.appending(path: "config.json")
    }

    func load() -> CLIConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(CLIConfig.self, from: data) else { return CLIConfig() }
        return config
    }

    func save(_ config: CLIConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    func update(_ change: (inout CLIConfig) throws -> Void) throws {
        var config = load()
        try change(&config)
        try save(config)
    }
}

/// The keys `addonctl config` accepts.
enum ConfigKey: String, CaseIterable, Sendable {
    case githubToken = "github-token"
    case defaultChannel = "default-channel"
    case defaultInstall = "default-install"
}

/// `config get|set|unset` logic, separate from argument parsing so it can be tested.
struct ConfigService: Sendable {
    var store: ConfigStore
    var keychain: KeychainStore
    var environment: [String: String]

    /// The value to show for `key`. Tokens are masked.
    func get(_ key: ConfigKey) -> String? {
        switch key {
        case .githubToken:
            for name in ["ADDONS_GITHUB_TOKEN", "GITHUB_TOKEN"] {
                if let value = environment[name], !value.isEmpty { return "\(Self.mask(value)) (from $\(name))" }
            }
            return keychain.get().map { "\(Self.mask($0)) (from Keychain)" }
        case .defaultChannel:
            return store.load().defaultChannel?.rawValue
        case .defaultInstall:
            return store.load().defaultInstall
        }
    }

    /// Sets `key`. `default-install` must already be validated to an installation id by the caller.
    func set(_ key: ConfigKey, to value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CLIError.usage("No value given for \(key.rawValue).") }
        switch key {
        case .githubToken:
            try keychain.set(value)
        case .defaultChannel:
            guard let channel = Channel(rawValue: value.lowercased()) else {
                throw CLIError.usage("default-channel must be one of: \(Channel.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            try store.update { $0.defaultChannel = channel }
        case .defaultInstall:
            try store.update { $0.defaultInstall = value }
        }
    }

    func unset(_ key: ConfigKey) throws {
        switch key {
        case .githubToken: try keychain.delete()
        case .defaultChannel: try store.update { $0.defaultChannel = nil }
        case .defaultInstall: try store.update { $0.defaultInstall = nil }
        }
    }

    /// `ghp_abcdef123456` → `ghp_…3456`.
    static func mask(_ token: String) -> String {
        guard token.count > 8 else { return "••••" }
        let prefix = token.prefix(while: { $0 != "_" })
        let head = prefix.count < token.count && prefix.count <= 11 ? String(prefix) + "_" : String(token.prefix(4))
        return head + "…" + token.suffix(4)
    }
}
