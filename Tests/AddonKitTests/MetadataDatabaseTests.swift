import Foundation
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

    @Test func migrationTwoDropsLumpedClassicRows() async throws {
        let dir = try makeTempDirectory()
        let url = dir.appending(path: "metadata.sqlite")
        do {
            // Rewind to schema 1 and store rows as that version wrote them.
            let db = try MetadataDatabase(url: url)
            try await db.executeScript("PRAGMA user_version = 1")
            for flavor in ["forever", "mainline", "classic"] {
                try await db.execute("INSERT INTO support(full_name, flavor, status, checked_at) VALUES (?, ?, 'supported', ?)", "o/r", flavor, Date())
                try await db.execute("INSERT INTO details(full_name, flavor, fetched_at) VALUES (?, ?, ?)", "o/r", flavor, Date())
            }
            try await db.execute("INSERT INTO refresh_state(installation_id, last_refresh_at) VALUES (?, ?)", "abc", Date())
        }
        let migrated = try MetadataDatabase(url: url)
        #expect(try await migrated.schemaVersion() == 2)
        #expect(try await migrated.query("SELECT flavor FROM support ORDER BY flavor").map { $0.string(0) } == ["forever", "mainline"])
        #expect(try await migrated.query("SELECT flavor FROM details ORDER BY flavor").map { $0.string(0) } == ["forever", "mainline"])
        #expect(try await migrated.query("SELECT count(*) FROM refresh_state").first?.int(0) == 1)
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
