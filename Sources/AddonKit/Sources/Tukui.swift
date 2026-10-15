import Foundation

/// Tukui's keyless API (docs/features/sources.md). `v1/addons` lists every add-on with its
/// download link, so it's both the listing and the files lookup. It's a few kilobytes: just
/// ElvUI and Tukui.
struct Tukui: HostedSource {
    let id = SourceID.tukui
    let listingURL = URL(string: "https://api.tukui.org/v1/addons")!
    static let hosts: Set<String> = ["tukui.org", "www.tukui.org"]

    func entries(fromListing data: Data) throws -> [CatalogueEntry] {
        try decode(data).compactMap { addon in
            guard Self.isValidSlug(addon.slug) else { return nil }
            let ref = AddonRef(source: id, identifier: addon.slug)
            let flavors = Set((addon.patch ?? []).compactMap(Flavor.from(gameVersion:)))
            return CatalogueEntry(
                id: String(addon.id), name: addon.name, fullName: ref.key,
                url: addon.web_url.flatMap(URL.init(string:)) ?? webURL(for: addon.slug)!,
                description: addon.small_desc, lastUpdated: addon.last_update.flatMap(Self.date),
                flavors: Flavor.allCases.filter(flavors.contains).map(\.rawValue),
                source: id, author: addon.author,
                screenshots: addon.screenshots,
                folders: addon.directories
            )
        }
    }

    func filesURL(for identifiers: [String]) -> URL {
        listingURL
    }

    func files(from data: Data) throws -> [String: HostedFile] {
        var out: [String: HostedFile] = [:]
        for addon in try decode(data) {
            guard let url = URL(string: addon.url) else { continue }
            out[addon.slug] = HostedFile(
                identifier: addon.slug, name: addon.name, author: addon.author, version: addon.version,
                publishedAt: addon.last_update.flatMap(Self.date) ?? .distantPast, downloadURL: url,
                fileName: "\(addon.name)-\(addon.version).zip", summary: addon.desc,
                screenshots: addon.screenshots
            )
        }
        return out
    }

    /// `tukui:elvui`, or `tukui.org/elvui`.
    func parse(_ input: String) -> AddonRef? {
        if let value = HostedSources.value(after: id.rawValue, in: input) {
            return Self.isValidSlug(value) ? AddonRef(source: id, identifier: value.lowercased()) : nil
        }
        guard let path = HostedSources.path(of: input, hosts: Self.hosts) else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count == 1, Self.isValidSlug(String(parts[0])) else { return nil }
        return AddonRef(source: id, identifier: parts[0].lowercased())
    }

    func webURL(for identifier: String) -> URL? {
        URL(string: "https://tukui.org/\(identifier)")
    }

    static func isValidSlug(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `2026-10-13`, at midnight UTC.
    static func date(_ text: String) -> Date? {
        try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash))
    }

    private func decode(_ data: Data) throws -> [Addon] {
        try JSONDecoder().decode([Addon].self, from: data)
    }

    private struct Addon: Decodable {
        var id: Int
        var slug: String
        var author: String?
        var name: String
        var url: String
        var version: String
        var patch: [String]?
        var last_update: String?
        var web_url: String?
        var small_desc: String?
        var desc: String?
        var screenshot_url: String?
        var gallery_url: [String]?
        /// The top-level folders the download ships.
        var directories: [String]?

        var screenshots: [URL] {
            var urls: [URL] = []
            for text in [screenshot_url].compactMap(\.self) + (gallery_url ?? []) {
                if let url = URL(string: text), !urls.contains(url) { urls.append(url) }
            }
            return urls
        }
    }
}
