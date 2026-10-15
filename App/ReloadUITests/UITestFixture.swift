import AddonKit
import Foundation

/// A throwaway data folder for the UI tests (docs/development.md#ui-tests): a fake Forever
/// installation and 600 WoWInterface catalogue rows, marked as refreshed and downloaded so
/// the app starts without the first-launch sheet and makes no requests. Hosted rows are
/// used because Browse never checks them in the background, and the first 20 have their
/// details stored, so opening them needs no network either.
struct UITestFixture {
    static let rowCount = 600
    static let rowsWithDetails = 20

    let root: URL
    var dataDirectory: URL { root.appending(path: "Data", directoryHint: .isDirectory) }

    static func make() async throws -> UITestFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ReloadUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fixture = UITestFixture(root: root)
        let flavorFolder = root.appending(path: "World of Warcraft/_classic_beta_", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: flavorFolder.appending(path: "Interface/AddOns", directoryHint: .isDirectory), withIntermediateDirectories: true)

        let manager = AddonManager(
            directories: AppDirectories(root: fixture.dataDirectory),
            locator: InstallationLocator(baseFolders: [], findApps: { [] }))
        let installation = try await manager.addInstallation(at: flavorFolder)
        try await seed(manager.database, installationID: installation.id)
        return fixture
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func seed(_ database: MetadataDatabase, installationID: String) async throws {
        let now = Date()
        let encoder = JSONEncoder()
        var files: [(key: String, json: String)] = []
        for i in 0..<rowsWithDetails {
            let file = HostedFile(
                identifier: "\(9000 + i)", name: "Test Addon \(i)", author: "Tester", version: "1.\(i)",
                publishedAt: now, downloadURL: URL(string: "https://example.invalid/\(i).zip")!, fileName: "\(i).zip",
                summary: "**Test Addon \(i)** for the UI tests.", changelog: "Changes in 1.\(i)")
            files.append(("wowinterface:\(9000 + i)", String(decoding: try encoder.encode(file), as: UTF8.self)))
        }
        let detailRows = files
        _ = try await database.transaction { db in
            for i in 0..<rowCount {
                try db.execute("""
                    INSERT INTO catalogue(full_name, id, name, description, url, last_updated, flavors, has_release_json,
                        source, first_seen_at, seen_at, changed_at, author)
                    VALUES (?, ?, ?, ?, ?, ?, 'forever,mainline', 0, 'wowinterface', ?, ?, ?, 'Tester')
                    """,
                    "wowinterface:\(9000 + i)", "\(9000 + i)", "Test Addon \(i)", "A made-up add-on for the UI tests, number \(i).",
                    "https://www.wowinterface.com/downloads/info\(9000 + i)", now.addingTimeInterval(-Double(i) * 3600), now, now, now)
            }
            for row in detailRows {
                try db.execute("INSERT INTO hosted_files(full_name, json, fetched_at) VALUES (?, ?, ?)", row.key, row.json, now)
            }
            // Everything counts as fresh: no first-launch sheet, no refresh, no listing downloads.
            try db.execute("INSERT INTO catalogue_state(id, fetched_at) VALUES (1, ?)", now)
            for source in ["wowinterface", "tukui"] {
                try db.execute("INSERT INTO source_state(source, fetched_at) VALUES (?, ?)", source, now)
            }
            try db.execute("INSERT INTO refresh_state(installation_id, last_refresh_at) VALUES (?, ?)", installationID, now)
            return 0
        }
    }
}
