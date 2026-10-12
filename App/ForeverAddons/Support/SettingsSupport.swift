import AddonKit
import AppKit
import Observation

/// The Settings window's tabs, in order. Remembered under `SettingsKey.settingsTab`.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, github, commandLine, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .github: "GitHub"
        case .commandLine: "Command Line"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .github: "person.badge.key"
        case .commandLine: "terminal"
        case .advanced: "gearshape.2"
        }
    }
}

/// The Dock and app switcher icon. Assets are `AltIcon-*` imagesets in the asset catalog.
///
/// Only `NSApp.applicationIconImage` changes: Finder reads the bundle's icon, and rewriting
/// the bundle (or `NSWorkspace.setIcon`) would break the code signature (decision 0022).
enum AppIconChoice: String, CaseIterable, Identifiable {
    case classic, rune, scroll, gilded

    var id: Self { self }

    var assetName: String {
        switch self {
        case .classic: "AltIcon-Classic"
        case .rune: "AltIcon-Rune"
        case .scroll: "AltIcon-Scroll"
        case .gilded: "AltIcon-Gilded"
        }
    }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .rune: "Rune"
        case .scroll: "Scroll"
        case .gilded: "Gilded"
        }
    }

    /// The stored choice, `.classic` when missing or unknown.
    static func stored(in defaults: UserDefaults) -> AppIconChoice {
        defaults.string(forKey: SettingsKey.appIcon).flatMap(AppIconChoice.init(rawValue:)) ?? .classic
    }

    func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: SettingsKey.appIcon)
    }

    /// The artwork, or nil when the asset isn't in this build.
    var image: NSImage? { NSImage(named: assetName) }

    /// What `NSApp.applicationIconImage` gets: nil for Classic, so the bundle icon is used,
    /// and nil when the artwork is missing, rather than a blank Dock tile.
    var dockImage: NSImage? { self == .classic ? nil : image }

    func apply() {
        NSApp.applicationIconImage = dockImage
    }
}

/// The one-time first-launch steps: the seeding sheet and the `addonctl` offer.
enum FirstLaunchSteps {
    static let keys = [AppModel.didSeedKey, CommandLineToolModel.didOfferKey]

    static func reset(in defaults: UserDefaults) {
        for key in keys { defaults.removeObject(forKey: key) }
    }
}

/// Where the GitHub token in use comes from, in the core's order: the environment wins
/// over the Keychain.
enum GitHubTokenSource: Equatable {
    case environment(String)
    case keychain
    case none

    static let environmentVariables = ["ADDONS_GITHUB_TOKEN", "GITHUB_TOKEN"]

    static func variable(in environment: [String: String]) -> String? {
        environmentVariables.first { !(environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }

    init(environment: [String: String], hasKeychainToken: Bool) {
        if let name = Self.variable(in: environment) {
            self = .environment(name)
        } else {
            self = hasKeychainToken ? .keychain : .none
        }
    }

    var description: String {
        switch self {
        case .environment(let name): "Environment variable \(name)"
        case .keychain: "Keychain"
        case .none: "None (60 requests an hour)"
        }
    }
}

/// The Settings token field: the Keychain token and where the token in use comes from.
@Observable @MainActor
final class GitHubTokenModel {
    var token = ""
    private(set) var hasKeychainToken = false
    private(set) var message: String?
    private(set) var error: String?
    let environmentVariable: String?

    /// Nil in snapshots, so they never read the real Keychain.
    @ObservationIgnored private let keychain: KeychainStore?

    init(keychain: KeychainStore?, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.keychain = keychain
        self.environmentVariable = GitHubTokenSource.variable(in: environment)
    }

    var source: GitHubTokenSource {
        environmentVariable.map(GitHubTokenSource.environment) ?? (hasKeychainToken ? .keychain : .none)
    }

    var canSave: Bool { !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func load() {
        guard let keychain else { return }
        let stored = keychain.get()
        token = stored ?? ""
        show(hasToken: stored != nil, message: stored == nil ? "No token saved." : "Token saved in Keychain.")
    }

    /// Returns whether the Keychain changed, so the caller tells the manager.
    func save() -> Bool {
        guard let keychain else { return false }
        do {
            try keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines))
            show(hasToken: true, message: "Token saved in Keychain.")
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func remove() -> Bool {
        guard let keychain else { return false }
        do {
            try keychain.delete()
            token = ""
            show(hasToken: false, message: "Token removed.")
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Sets the displayed state without the Keychain (snapshots).
    func show(hasToken: Bool, message: String?) {
        hasKeychainToken = hasToken
        self.message = message
        error = nil
    }
}
