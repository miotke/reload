import AddonKit
import Foundation

/// Read-only views of the shared metadata database for `cache`, `doctor` and `info`.
/// The core owns every write; the one exception is `cache clear --metadata`.
enum MetadataInfo {
    /// `metadata.sqlite` and its write-ahead log, in Application Support.
    static func databaseURL(_ directories: AppDirectories) -> URL {
        directories.applicationSupport.appending(path: MetadataDatabase.fileName, directoryHint: .notDirectory)
    }

    static func walURL(_ directories: AppDirectories) -> URL {
        directories.applicationSupport.appending(path: MetadataDatabase.fileName + "-wal", directoryHint: .notDirectory)
    }

    struct Counts: Equatable {
        var catalogue: Int
        var support: Int
    }

    static func counts(_ database: MetadataDatabase) async throws -> Counts {
        let catalogue = try await database.query("SELECT COUNT(*) FROM catalogue").first?.int(0) ?? 0
        let support = try await database.query("SELECT COUNT(*) FROM support WHERE status IS NOT NULL").first?.int(0) ?? 0
        return Counts(catalogue: catalogue, support: support)
    }

    /// A stored GitHub rate-limit row (`core` or `search`) and when it was last written.
    struct RateLimit: Equatable {
        var remaining: Int?
        var resetAt: Date?
        var updatedAt: Date?
    }

    static func rateLimit(_ resource: String, in database: MetadataDatabase) async -> RateLimit? {
        guard let row = try? await database.query(
            "SELECT remaining, reset_at, updated_at FROM rate_limit WHERE resource = ?", resource).first else { return nil }
        return RateLimit(remaining: row.int(0), resetAt: row.date(1), updatedAt: row.date(2))
    }

    /// Where the README was last found (`""` means the repo has none), if it was looked for.
    static func readmePath(for ref: AddonRef, in database: MetadataDatabase) async -> String? {
        try? await database.query("SELECT readme_path FROM repo_meta WHERE full_name = ?", ref.identifier).first?.string(0)
    }

    /// Tables `cache clear --metadata` empties. `rate_limit` is kept on purpose: forgetting
    /// an exhausted quota would let the app and CLI spend requests GitHub will refuse.
    static let clearedTables = [
        "catalogue", "catalogue_state", "repo_meta", "support", "details", "release_json", "refresh_state", "search_cache",
    ]

    /// Empties the metadata tables in one transaction, then gives the space back. The file
    /// itself stays: the app may have it open, and deleting an open WAL database corrupts it.
    static func clear(_ database: MetadataDatabase) async throws {
        let tables = clearedTables
        try await database.transaction { db in
            for table in tables { try db.execute("DELETE FROM \(table)") }
        }
        // Both fail harmlessly (busy) while another process is reading.
        _ = try? await database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        _ = try? await database.execute("VACUUM")
    }
}
