import AddonKit
import Foundation

/// The `addons.json` written by `export` and read by `import` (docs/cli/commands.md).
struct AddonsFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct Entry: Codable, Equatable, Sendable {
        /// `github:owner/repo`.
        var ref: String
        /// For people reading the file; ignored on import.
        var name: String?
        var channel: Channel
        var pinned: Bool
        /// Only written for pinned add-ons, so `import` can restore that exact release.
        var version: String?
    }

    var schemaVersion = AddonsFile.currentSchemaVersion
    var exportedAt: Date?
    var addons: [Entry]

    init(exportedAt: Date? = Date(), addons: [Entry]) {
        self.exportedAt = exportedAt
        self.addons = addons
    }

    init(installed: [InstalledAddon], exportedAt: Date? = Date()) {
        let entries = installed
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { addon in
                Entry(ref: addon.id.description, name: addon.name, channel: addon.channel, pinned: addon.pinned, version: addon.pinned ? addon.version : nil)
            }
        self.init(exportedAt: exportedAt, addons: entries)
    }

    func encoded() throws -> Data {
        try JSONOutput.encoder().encode(self)
    }

    static func decode(_ data: Data) throws -> AddonsFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: AddonsFile
        do {
            file = try decoder.decode(AddonsFile.self, from: data)
        } catch {
            throw CLIError.usage("Not a valid addons.json file: \(error.localizedDescription)")
        }
        guard file.schemaVersion <= currentSchemaVersion else {
            throw CLIError.usage("addons.json uses format \(file.schemaVersion); this addonctl reads up to \(currentSchemaVersion).")
        }
        return file
    }
}
