import AddonKit
import AppKit

/// `@AppStorage` keys shared by the app and Settings.
enum SettingsKey {
    static let defaultChannel = "defaultChannel"
    static let checkForUpdatesOnLaunch = "checkForUpdatesOnLaunch"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let appearance = "appearance"
    static let appIcon = "appIcon"
    static let settingsTab = "settingsTab"
}

/// Light, dark or the system's choice, set in Settings or View ▸ Appearance.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Use System Setting"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Sets the whole app's appearance, so window chrome, sheets and menus follow too
    /// (`preferredColorScheme` only reaches SwiftUI content).
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Focuses the window's toolbar search field (⌘F from any tab).
@MainActor
enum SearchFieldFocus {
    static func focus() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if let item = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
        } else if let field = window.contentView?.firstDescendant(of: NSSearchField.self) {
            window.makeFirstResponder(field)
        }
    }
}

extension NSView {
    fileprivate func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = (subview as? T) ?? subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

extension Channel {
    var title: String {
        switch self {
        case .stable: "Stable"
        case .prerelease: "Pre-release"
        }
    }
}

extension AddonRef {
    var sourceName: String { source.displayName }
}

extension Installation {
    var displayName: String {
        switch (flavor, root.lastPathComponent) {
        case (.forever, "_classic_beta_"): "Forever Beta"
        default: flavor.displayName
        }
    }
}

/// Least-recently-used order for a cache whose values live elsewhere (an observed
/// dictionary), so reordering on use doesn't count as a change to observe.
nonisolated struct RecentKeys<Key: Hashable> {
    let limit: Int
    /// Least recently used first.
    private(set) var keys: [Key] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Marks `key` as just used; returns the keys that fell out and should be dropped.
    mutating func use(_ key: Key) -> [Key] {
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) }
        keys.append(key)
        guard keys.count > limit else { return [] }
        let evicted = Array(keys.prefix(keys.count - limit))
        keys.removeFirst(evicted.count)
        return evicted
    }

    mutating func remove(_ key: Key) {
        keys.removeAll { $0 == key }
    }
}
