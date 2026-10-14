import Foundation

/// WoWInterface's keyless MMOUI API (docs/features/sources.md):
/// - `filelist.json`: every add-on (~8,000, ~5.6 MB) with its version, date, folders and the
///   game versions its author ticked.
/// - `filedetails/<id>,<id>.json`: the download link, description and changelog of each file.
struct WoWInterface: HostedSource {
    let id = SourceID.wowinterface
    let listingURL = URL(string: "https://api.mmoui.com/v3/game/WOW/filelist.json")!
    static let hosts: Set<String> = ["wowinterface.com", "www.wowinterface.com"]

    func entries(fromListing data: Data) throws -> [CatalogueEntry] {
        try JSONDecoder().decode([ListingFile].self, from: data).compactMap { file in
            guard Self.isValidID(file.UID) else { return nil }
            let ref = AddonRef(source: id, identifier: file.UID)
            let flavors = Set((file.UICompatibility ?? []).compactMap { Flavor.from(gameVersion: $0.version) })
            return CatalogueEntry(
                id: file.UID, name: file.UIName, fullName: ref.key,
                url: file.UIFileInfoURL.flatMap(URL.init(string:)) ?? webURL(for: file.UID)!,
                lastUpdated: file.UIDate.map { Date(timeIntervalSince1970: $0.value / 1000) },
                flavors: Flavor.allCases.filter(flavors.contains).map(\.rawValue),
                source: id, author: file.UIAuthorName,
                screenshots: (file.UIIMGs ?? []).compactMap(URL.init(string:))
            )
        }
    }

    func filesURL(for identifiers: [String]) -> URL {
        URL(string: "https://api.mmoui.com/v3/game/WOW/filedetails/\(identifiers.joined(separator: ",")).json")!
    }

    func files(from data: Data) throws -> [String: HostedFile] {
        var out: [String: HostedFile] = [:]
        for file in try JSONDecoder().decode([DetailsFile].self, from: data) {
            guard let url = URL(string: file.UIDownload), let date = file.UIDate else { continue }
            out[file.UID] = HostedFile(
                identifier: file.UID, name: file.UIName, author: file.UIAuthorName, version: file.UIVersion,
                publishedAt: Date(timeIntervalSince1970: date.value / 1000), downloadURL: url,
                fileName: file.UIFileName ?? "\(file.UID).zip",
                summary: file.UIDescription.map(BBCode.markdown), changelog: file.UIChangeLog.map(BBCode.markdown)
            )
        }
        return out
    }

    /// `wowinterface:3826`, or a file's page or download link:
    /// `wowinterface.com/downloads/info3826-CTMod.html`, `…/downloads/fileinfo.php?id=3826`,
    /// `…/downloads/download3826-CTMod`.
    func parse(_ input: String) -> AddonRef? {
        if let value = HostedSources.value(after: id.rawValue, in: input) {
            return Self.isValidID(value) ? AddonRef(source: id, identifier: value) : nil
        }
        guard let path = HostedSources.path(of: input, hosts: Self.hosts) else { return nil }
        let patterns = [#"^/downloads/(?:info|download)(\d+)"#, #"^/downloads/fileinfo\.php\?(?:.*&)?id=(\d+)"#]
        for pattern in patterns {
            if let match = path.firstMatch(of: try! Regex(pattern)), let digits = match.output[1].substring {
                return AddonRef(source: id, identifier: String(digits))
            }
        }
        return nil
    }

    func webURL(for identifier: String) -> URL? {
        URL(string: "https://www.wowinterface.com/downloads/info\(identifier)")
    }

    static func isValidID(_ s: String) -> Bool {
        (1...10).contains(s.count) && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber)
    }

    // MARK: - JSON

    private struct Compatibility: Decodable {
        var version: String
    }

    private struct ListingFile: Decodable {
        var UID: String
        var UIName: String
        var UIAuthorName: String?
        var UIDate: FlexibleNumber?
        var UIFileInfoURL: String?
        var UICompatibility: [Compatibility]?
        var UIIMGs: [String]?
    }

    private struct DetailsFile: Decodable {
        var UID: String
        var UIName: String
        var UIAuthorName: String?
        var UIVersion: String
        var UIDate: FlexibleNumber?
        var UIFileName: String?
        var UIDownload: String
        var UIDescription: String?
        var UIChangeLog: String?
    }
}

/// A number the API sends as a JSON number in one endpoint and a string in another
/// (`UIDate` is both).
struct FlexibleNumber: Decodable, Hashable {
    var value: Double

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let number = Double(try container.decode(String.self)) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number")
        }
    }
}
