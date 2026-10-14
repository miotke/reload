import Foundation

/// Searches the add-ons already in an installation (docs/features/search.md, "Installed" layer)
/// with the same matching rules as the catalogue.
///
/// Managed add-ons match on name, folders and `owner/repo`. Unmanaged folders match on
/// folder name and TOC title/notes, but are only returned when they have a
/// `suggestedRef`, since a result needs a ref to act on.
public struct InstalledSearchProvider: SearchProvider {
    private struct Item: Sendable {
        var document: SearchDocument
        var result: SearchResult
    }

    private let items: [Item]

    public init(addons: [AddonStatus]) {
        var items: [Item] = []
        for status in addons {
            switch status {
            case .managed(let addon, _):
                let owner = Self.owner(of: addon.id)
                items.append(Item(
                    document: SearchDocument(name: addon.name, otherFields: [addon.id.identifier] + addon.folders),
                    result: SearchResult(
                        // A quota-free install has no real release date (a negative, synthetic
                        // release ID); its `publishedAt` is when it was installed.
                        id: addon.id, name: addon.name, owner: owner, lastUpdated: addon.releaseID >= 0 ? addon.publishedAt : nil,
                        installed: addon, origin: [.installed]
                    )
                ))
            case .unmanaged(let unmanaged):
                guard let ref = unmanaged.suggestedRef else { continue }
                let folder = unmanaged.folder
                let title = unmanaged.toc?.displayTitle.flatMap(Self.nonEmpty)
                let notes = unmanaged.toc?.notes.flatMap(Self.nonEmpty)
                items.append(Item(
                    document: SearchDocument(name: title ?? folder, otherFields: unmanaged.folders + [ref.identifier, notes]),
                    result: SearchResult(
                        id: ref, name: title ?? folder, summary: notes, owner: Self.owner(of: ref), origin: [.installed]
                    )
                ))
            }
        }
        self.items = items
    }

    public init(installed: [InstalledAddon]) {
        self.init(addons: installed.map { .managed($0, missingFolders: []) })
    }

    public func search(_ query: SearchQuery) -> [SearchResult] {
        guard let plan = SearchPlan(query.text) else { return [] }
        return items
            .compactMap { item in item.document.tier(for: plan).map { (item.result, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    /// The repo owner; hosted refs carry no author, so theirs is empty.
    static func owner(of ref: AddonRef) -> String {
        guard ref.source == .github else { return "" }
        return String(ref.identifier.split(separator: "/").first ?? Substring(ref.identifier))
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
