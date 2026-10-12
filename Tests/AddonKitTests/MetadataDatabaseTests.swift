import Foundation
import SQLite3
import Testing
@testable import AddonKit

@Suite struct MetadataDatabaseTests {
    @Test func migratesOnOpenAndReopens() async throws {
        let dir = try makeTempDirectory()
        let url = dir.appending(path: "metadata.sqlite")
        do {
            let db = try MetadataDatabase(url: url)
            #expect(try await db.schemaVersion() == MetadataDatabase.migrations.count)
            try await db.execute("INSERT INTO rate_limit(resource, remaining, updated_at) VALUES (?, ?, ?)", "core", 5, Date())
        }
        let reopened = try MetadataDatabase(url: url)
        #expect(try await reopened.schemaVersion() == MetadataDatabase.migrations.count)
        #expect(try await reopened.query("SELECT remaining FROM rate_limit WHERE resource = ?", "core").first?.int(0) == 5)
        #expect(try await reopened.query("PRAGMA journal_mode").first?.string(0) == "wal")
    }

    /// A database file at `version`, built with the shipped steps up to it, as that release left it.
    func database(atVersion version: Int, _ setup: (OpaquePointer) -> Void = { _ in }) throws -> URL {
        let url = try makeTempDirectory().appending(path: "metadata.sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for step in MetadataDatabase.migrations.prefix(version) {
            try #require(sqlite3_exec(db, step, nil, nil, nil) == SQLITE_OK)
        }
        try #require(sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK)
        setup(db!)
        return url
    }

    @Test func migrationTwoDropsLumpedClassicRows() async throws {
        let url = try database(atVersion: 1) { db in
            for flavor in ["forever", "mainline", "classic"] {
                sqlite3_exec(db, "INSERT INTO support(full_name, flavor, status, checked_at) VALUES ('o/r', '\(flavor)', 'supported', 1)", nil, nil, nil)
                sqlite3_exec(db, "INSERT INTO details(full_name, flavor, fetched_at) VALUES ('o/r', '\(flavor)', 1)", nil, nil, nil)
            }
            sqlite3_exec(db, "INSERT INTO refresh_state(installation_id, last_refresh_at) VALUES ('abc', 1)", nil, nil, nil)
        }
        let migrated = try MetadataDatabase(url: url)
        #expect(try await migrated.schemaVersion() == MetadataDatabase.migrations.count)
        #expect(try await migrated.query("SELECT flavor FROM support ORDER BY flavor").map { $0.string(0) } == ["forever", "mainline"])
        #expect(try await migrated.query("SELECT flavor FROM details ORDER BY flavor").map { $0.string(0) } == ["forever", "mainline"])
        #expect(try await migrated.query("SELECT count(*) FROM refresh_state").first?.int(0) == 1)
    }

    @Test func migrationThreeMovesFailuresBesideTheVerdict() async throws {
        let url = try database(atVersion: 2) { db in
            sqlite3_exec(db, """
                INSERT INTO support(full_name, flavor, status, version, tag, checked_at) VALUES
                    ('o/good', 'forever', 'supported', 'v1', 'v1', 100),
                    ('o/bad', 'forever', 'error', NULL, 'v0', 200);
                INSERT INTO repo_meta(full_name, latest_tag, tag_checked_at) VALUES ('o/good', 'v1', 100);
                """, nil, nil, nil)
        }
        let db = try MetadataDatabase(url: url)
        #expect(try await db.schemaVersion() == 3)
        let rows = try await db.query("SELECT full_name, status, checked_at, error_at, retry_after FROM support ORDER BY full_name")
        #expect(rows.map { $0.string(0) } == ["o/bad", "o/good"])
        #expect(rows[0].string(1) == nil && rows[0].double(2) == nil, "a failure is no longer a status")
        #expect(rows[0].double(3) == 200 && rows[0].double(4) == 1100)
        #expect(rows[1].string(1) == "supported" && rows[1].double(3) == nil)
        #expect(try await db.query("SELECT api_checked_at FROM repo_meta").first?.double(0) == nil)
        try await db.execute("INSERT INTO release_json(full_name, tag, json, fetched_at) VALUES ('o/good', 'v1', NULL, 1)")
    }

    @Test func preparedStatementsStepInABatch() async throws {
        let db = try MetadataDatabase.inMemory()
        try await db.executeScript("CREATE TABLE t (k TEXT PRIMARY KEY, v INTEGER)")
        let changed = try await db.transaction { db in
            let insert = try db.prepare("INSERT INTO t VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v WHERE t.v IS NOT excluded.v")
            var changed = 0
            for (k, v) in [("a", 1), ("b", 2), ("a", 1), ("a", 3)] {
                changed += try db.step(insert, [.text(k), .integer(Int64(v))])
            }
            return changed
        }
        #expect(changed == 3, "the unchanged re-upsert changes nothing")
        #expect(try await db.query("SELECT v FROM t ORDER BY k").map { $0.int(0) } == [3, 2])
        await #expect(throws: SQLiteError.self) {
            try await db.transaction { db in _ = try db.step(try db.prepare("SELECT ?"), []) }
        }
    }

    @Test func bindsAndReadsEveryType() async throws {
        let db = try MetadataDatabase.inMemory()
        try await db.executeScript("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, d REAL, n TEXT, f INTEGER)")
        let date = Date(timeIntervalSince1970: 1_800_000_000.5)
        let missing: String? = nil
        try await db.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?, ?)",
                             Int64(42), 1.5, "héllo 'quoted'", Data([0, 1, 2]), date, missing, true)
        let row = try #require(try await db.query("SELECT * FROM t").first)
        #expect(row.int64(0) == 42)
        #expect(row.double(1) == 1.5)
        #expect(row.string(2) == "héllo 'quoted'")
        #expect(row.data(3) == Data([0, 1, 2]))
        #expect(row.date(4) == date)
        #expect(row.string(5) == nil)
        #expect(row.bool(6))
    }

    @Test func wrongArgumentCountAndBadSQLThrowWithSQLiteMessage() async throws {
        let db = try MetadataDatabase.inMemory()
        await #expect(throws: SQLiteError.self) { try await db.execute("SELECT ?, ?", 1) }
        do {
            try await db.execute("SELEKT 1")
            Issue.record("expected an error")
        } catch let error as SQLiteError {
            #expect(error.message.contains("syntax error"))
        }
    }

    @Test func transactionsCommitOrRollBack() async throws {
        let db = try MetadataDatabase.inMemory()
        try await db.executeScript("CREATE TABLE t (v INTEGER)")
        try await db.transaction { db in
            try db.execute("INSERT INTO t VALUES (1)")
            _ = try db.transaction { try $0.execute("INSERT INTO t VALUES (2)") }
        }
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await db.transaction { db in
                try db.execute("INSERT INTO t VALUES (3)")
                throw Boom()
            }
        }
        #expect(try await db.query("SELECT v FROM t ORDER BY v").map { $0.int(0) } == [1, 2])
    }

    @Test func cachedStatementsAreReusable() async throws {
        let db = try MetadataDatabase.inMemory()
        try await db.executeScript("CREATE TABLE t (v INTEGER)")
        for i in 0..<5 { try await db.execute("INSERT INTO t VALUES (?)", i) }
        #expect(try await db.query("SELECT count(*) FROM t WHERE v >= ?", 2).first?.int(0) == 3)
        #expect(try await db.query("SELECT count(*) FROM t WHERE v >= ?", 4).first?.int(0) == 1)
    }

    @Test func systemSQLiteHasFTS5() async throws {
        // Search ranking stays in the in-memory `SearchIndex` (FTS5 can't reproduce its
        // tiers); this documents that FTS5 is there if that changes.
        let db = try MetadataDatabase.inMemory()
        try await db.executeScript("CREATE VIRTUAL TABLE fts USING fts5(full_name UNINDEXED, tokens)")
        try await db.execute("INSERT INTO fts(full_name, tokens) VALUES (?, ?)", "a/b", "deadly boss mods")
        #expect(try await db.query("SELECT full_name FROM fts WHERE fts MATCH ?", #""bos"*"#).first?.string(0) == "a/b")
    }
}
