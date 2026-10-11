import AddonKit
import AppKit

/// `@AppStorage` keys shared by the app and Settings.
enum SettingsKey {
    static let defaultChannel = "defaultChannel"
    static let checkForUpdatesOnLaunch = "checkForUpdatesOnLaunch"
    static let showMenuBarExtra = "showMenuBarExtra"
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
    var webURL: URL? {
        switch source {
        case .github: URL(string: "https://github.com/\(identifier)")
        case .wowinterface, .tukui: nil
        }
    }

    var sourceName: String {
        switch source {
        case .github: "GitHub"
        case .wowinterface: "WoWInterface"
        case .tukui: "Tukui"
        }
    }
}

extension Installation {
    var displayName: String {
        switch (flavor, root.lastPathComponent) {
        case (.forever, "_classic_beta_"): "Forever Beta"
        case (.forever, _): "Forever"
        case (.mainline, _): "Retail"
        case (.classic, _): "Classic"
        }
    }
}
