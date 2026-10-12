import AddonKit
import Foundation

// The sidebar's sections and what each one shows (docs/app/navigation.md). Library
// sections are filters over the Installed rows `InstalledModel` already builds; Browse and the
// categories are catalogue queries. Display mapping only: whether an add-on has an update or is
// pinned comes from the row, which takes it from the core's `UpdateOffer` and the store.

/// A filtered view of the installation's Installed table.
nonisolated enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case installed, updates, unmanaged, pinned
    var id: Self { self }

    var title: String {
        switch self {
        case .installed: "Installed"
        case .updates: "Updates"
        case .unmanaged: "Unmanaged"
        case .pinned: "Pinned"
        }
    }

    var symbol: String {
        switch self {
        case .installed: "puzzlepiece.extension"
        case .updates: "arrow.down.circle"
        case .unmanaged: "questionmark.folder"
        case .pinned: "pin"
        }
    }

    /// Installed lists managed add-ons only; unmanaged folders have their own section.
    func includes(_ row: InstalledRow) -> Bool {
        switch self {
        case .installed: row.isManaged
        case .updates: row.isManaged && row.availableVersion != nil
        case .unmanaged: !row.isManaged
        case .pinned: row.isManaged && row.isPinned
        }
    }

    var searchPrompt: String {
        switch self {
        case .installed: "Filter installed add-ons"
        case .updates: "Filter updates"
        case .unmanaged: "Filter unmanaged folders"
        case .pinned: "Filter pinned add-ons"
        }
    }
}

/// The sidebar badges: rows per library section, before the search filter.
nonisolated struct LibraryCounts: Equatable, Sendable {
    var installed = 0
    var updates = 0
    var unmanaged = 0
    var pinned = 0

    init() {}

    init(rows: [InstalledRow]) {
        for row in rows {
            if LibrarySection.installed.includes(row) { installed += 1 }
            if LibrarySection.updates.includes(row) { updates += 1 }
            if LibrarySection.unmanaged.includes(row) { unmanaged += 1 }
            if LibrarySection.pinned.includes(row) { pinned += 1 }
        }
    }

    subscript(section: LibrarySection) -> Int {
        switch section {
        case .installed: installed
        case .updates: updates
        case .unmanaged: unmanaged
        case .pinned: pinned
        }
    }
}

/// What the sidebar has selected. Stored per window as its `rawValue` (`@SceneStorage`).
nonisolated enum SidebarItem: Hashable, Sendable, RawRepresentable {
    case library(LibrarySection)
    case browse
    /// A `SearchCategory.id`.
    case category(String)

    init?(rawValue: String) {
        if rawValue == "browse" {
            self = .browse
        } else if rawValue.hasPrefix("category:") {
            self = .category(String(rawValue.dropFirst("category:".count)))
        } else if let section = LibrarySection(rawValue: rawValue) {
            self = .library(section)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .library(let section): section.rawValue
        case .browse: "browse"
        case .category(let id): "category:\(id)"
        }
    }

    var librarySection: LibrarySection? {
        if case .library(let section) = self { section } else { nil }
    }

    var isLibrary: Bool { librarySection != nil }

    /// The selected category, or nil for Browse and the library (or a category that's gone).
    func category(in categories: [SearchCategory]) -> SearchCategory? {
        guard case .category(let id) = self else { return nil }
        return categories.first { $0.id == id }
    }

    func searchPrompt(categories: [SearchCategory]) -> String {
        if let section = librarySection { return section.searchPrompt }
        if let category = category(in: categories) { return "Search \(category.title)" }
        return "Search add-ons"
    }

    /// The catalogue query for Browse and categories: what's typed, narrowed by the category's
    /// own query (search words must all match, so "bag sort" searches within Bags). Nil in the
    /// library, where the text filters instead.
    func browseQuery(typed: String, categories: [SearchCategory]) -> String? {
        guard !isLibrary else { return nil }
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let category = category(in: categories) else { return text }
        return text.isEmpty ? category.query : "\(category.query) \(text)"
    }
}
