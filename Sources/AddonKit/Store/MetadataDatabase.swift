import Foundation
import SQLite3

/// A SQLite failure, with SQLite's own message.
public struct SQLiteError: Error, Sendable, Equatable, LocalizedError {
    public var code: Int32
    public var message: String

    public var errorDescription: String? { "Database error \(code): \(message)" }
}

/// A value bound to, or read from, a SQL statement. Dates are stored as Unix seconds (REAL).
public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// Types that can be bound as statement parameters.
public protocol SQLBindable: Sendable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { public var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .integer(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .real(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .integer(self ? 1 : 0) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .real(timeIntervalSince1970) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// One result row, with typed accessors by column index.
public struct SQLRow: Sendable, Hashable {
    public var values: [SQLValue]

    public subscript(_ index: Int) -> SQLValue { values[index] }

    public func int64(_ i: Int) -> Int64? {
        switch values[i] {
        case .integer(let v): v
        case .real(let v): Int64(v)
        case .text(let s): Int64(s)
        default: nil
        }
    }

    public func int(_ i: Int) -> Int? { int64(i).map(Int.init) }

    public func double(_ i: Int) -> Double? {
        switch values[i] {
        case .integer(let v): Double(v)
        case .real(let v): v
        case .text(let s): Double(s)
        default: nil
        }
    }

    public func string(_ i: Int) -> String? {
        switch values[i] {
        case .text(let s): s
        case .integer(let v): String(v)
        case .real(let v): String(v)
        case .blob(let d): String(data: d, encoding: .utf8)
        case .null: nil
        }
    }

    public func data(_ i: Int) -> Data? {
        switch values[i] {
        case .blob(let d): d
        case .text(let s): Data(s.utf8)
        default: nil
        }
    }

    public func bool(_ i: Int) -> Bool { (int64(i) ?? 0) != 0 }

    public func date(_ i: Int) -> Date? { double(i).map(Date.init(timeIntervalSince1970:)) }
}

/// Shared metadata (catalogue, support verdicts, repo details, refresh and rate-limit state)
/// in `<applicationSupport>/metadata.sqlite`, through the system SQLite.
///
/// The app and `addonctl` open the same file, so it runs in WAL mode with a 5 s busy
/// timeout. The connection is opened without SQLite's own mutex: the actor is the only
/// thing that touches it. Schema changes are ordered `migrations`, tracked in
/// `PRAGMA user_version`, each applied in its own transaction on open.
public actor MetadataDatabase {
    public static let fileName = "metadata.sqlite"

    /// The database file, or nil for an in-memory database.
    public nonisolated let url: URL?
    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]
    private var transactionDepth = 0

    /// `SQLITE_TRANSIENT`: SQLite copies bound text and blobs before `bind` returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (creating if needed) the database at `url` and brings its schema up to date.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path(percentEncoded: false), url: url)
    }

    /// A private in-memory database, for tests and previews.
    public static func inMemory() throws -> MetadataDatabase {
        try MetadataDatabase(path: ":memory:", url: nil)
    }

    /// `<directories.applicationSupport>/metadata.sqlite`.
    public init(directories: AppDirectories) throws {
        try self.init(url: directories.applicationSupport.appending(path: Self.fileName, directoryHint: .notDirectory))
    }

    private init(path: String, url: URL?) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(db)
            throw SQLiteError(code: code, message: message)
        }
        self.handle = db
        self.url = url
        sqlite3_busy_timeout(db, 5_000)
        try Self.exec(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL; PRAGMA journal_size_limit=4194304;")
        try Self.migrate(db)
    }

    isolated deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_exec(handle, "PRAGMA optimize", nil, nil, nil)
        sqlite3_close_v2(handle)
    }

    // MARK: - Statements

    /// Runs `sql` with `arguments`; returns the number of rows changed.
    @discardableResult
    public func execute(_ sql: String, _ arguments: [any SQLBindable] = []) throws -> Int {
        let statement = try prepared(sql, arguments)
        defer { sqlite3_reset(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw error(code) }
        return Int(sqlite3_changes(handle))
    }

    @discardableResult
    public func execute(_ sql: String, _ arguments: any SQLBindable...) throws -> Int {
        try execute(sql, arguments)
    }

    /// Every row `sql` returns.
    public func query(_ sql: String, _ arguments: [any SQLBindable] = []) throws -> [SQLRow] {
        let statement = try prepared(sql, arguments)
        defer { sqlite3_reset(statement) }
        var rows: [SQLRow] = []
        let columns = sqlite3_column_count(statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error(code) }
            rows.append(SQLRow(values: (0..<columns).map { column(statement, $0) }))
        }
        return rows
    }

    public func query(_ sql: String, _ arguments: any SQLBindable...) throws -> [SQLRow] {
        try query(sql, arguments)
    }

    /// Several statements with no parameters, e.g. a migration script.
    public func executeScript(_ sql: String) throws {
        try Self.exec(handle, sql)
    }

    /// Runs `body` in a `BEGIN IMMEDIATE` transaction, committing if it returns and rolling
    /// back if it throws. The body is synchronous on purpose: a write lock must never be held
    /// across a network wait. Nested calls join the outer transaction.
    @discardableResult
    public func transaction<T: Sendable>(_ body: @Sendable (isolated MetadataDatabase) throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body(self)
        }
        try Self.exec(handle, "BEGIN IMMEDIATE")
        transactionDepth = 1
        defer { transactionDepth = 0 }
        do {
            let result = try body(self)
            try Self.exec(handle, "COMMIT")
            return result
        } catch {
            try? Self.exec(handle, "ROLLBACK")
            throw error
        }
    }

    // MARK: - Change notifications

    /// What a committed write touched, so the UI can patch only affected rows.
    public struct Change: Sendable, Hashable {
        public var tables: Set<String>
        /// Lower-cased `owner/repo` of the affected repos; empty means "many or unknown".
        public var repos: Set<String>
    }

    private var observers: [UUID: AsyncStream<Change>.Continuation] = [:]

    /// Writes committed through this connection. Other processes' writes don't appear here;
    /// compare `dataVersion()` on app activation for those.
    public func changes() -> AsyncStream<Change> {
        let (stream, continuation) = AsyncStream.makeStream(of: Change.self, bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// Call after a committed write.
    func notify(_ tables: Set<String>, repos: Set<String> = []) {
        guard !observers.isEmpty else { return }
        let change = Change(tables: tables, repos: Set(repos.map { $0.lowercased() }))
        for continuation in observers.values { continuation.yield(change) }
    }

    /// `PRAGMA data_version`: changes when another connection (the CLI) commits.
    public func dataVersion() throws -> Int64 {
        try query("PRAGMA data_version").first?.int64(0) ?? 0
    }

    /// The schema version (`PRAGMA user_version`).
    public func schemaVersion() throws -> Int {
        try query("PRAGMA user_version").first?.int(0) ?? 0
    }

    private func prepared(_ sql: String, _ arguments: [any SQLBindable]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
        } else {
            var raw: OpaquePointer?
            // Persistent: these statements are cached for the connection's lifetime.
            let code = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &raw, nil)
            guard code == SQLITE_OK, let raw else { throw error(code) }
            statements[sql] = raw
            statement = raw
        }
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == arguments.count else {
            throw SQLiteError(code: SQLITE_RANGE, message: "\(arguments.count) arguments for \(expected) parameters in: \(sql)")
        }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch argument.sqlValue {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .blob(let d): d.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            }
            guard code == SQLITE_OK else { throw error(code) }
        }
        return statement
    }

    private func column(_ statement: OpaquePointer, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, i))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, i)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, i))
            guard count > 0, let bytes = sqlite3_column_blob(statement, i) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw SQLiteError(code: code, message: text)
        }
    }

    // MARK: - Migrations

    /// Applies every migration past the stored `user_version`, each in its own transaction,
    /// so a crash mid-way leaves the file at a consistent earlier version.
    private static func migrate(_ db: OpaquePointer) throws {
        var current = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
            current = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        guard current < migrations.count else { return }
        for version in current..<migrations.count {
            try exec(db, "BEGIN IMMEDIATE")
            do {
                // Another process may have migrated while we waited for the lock.
                var check: OpaquePointer?
                var now = 0
                if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &check, nil) == SQLITE_OK, sqlite3_step(check) == SQLITE_ROW {
                    now = Int(sqlite3_column_int64(check, 0))
                }
                sqlite3_finalize(check)
                if now <= version {
                    try exec(db, migrations[version])
                    try exec(db, "PRAGMA user_version = \(version + 1)")
                }
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    /// Ordered schema steps. Never edit a shipped step; append a new one.
    static let migrations: [String] = [
        // 1: initial schema.
        """
        CREATE TABLE catalogue (
            full_name TEXT PRIMARY KEY COLLATE NOCASE,
            id TEXT NOT NULL,
            name TEXT NOT NULL,
            description TEXT,
            url TEXT NOT NULL,
            last_updated REAL,
            flavors TEXT NOT NULL DEFAULT '',
            curse_id INTEGER,
            wago_id TEXT,
            wowi_id INTEGER,
            has_release_json INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'catalogue',
            first_seen_at REAL NOT NULL,
            seen_at REAL NOT NULL,
            changed_at REAL NOT NULL
        ) WITHOUT ROWID;
        CREATE INDEX catalogue_last_updated ON catalogue(last_updated DESC);
        CREATE INDEX catalogue_seen_at ON catalogue(seen_at);

        CREATE TABLE catalogue_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            etag TEXT,
            fetched_at REAL,
            failed_at REAL
        );

        CREATE TABLE repo_meta (
            full_name TEXT PRIMARY KEY COLLATE NOCASE,
            latest_tag TEXT,
            tag_checked_at REAL,
            latest_published_at REAL,
            stars INTEGER,
            readme_path TEXT,
            readme_etag TEXT,
            readme_checked_at REAL
        );

        CREATE TABLE support (
            full_name TEXT NOT NULL COLLATE NOCASE,
            flavor TEXT NOT NULL,
            status TEXT NOT NULL,
            version TEXT,
            tag TEXT,
            checked_at REAL NOT NULL,
            PRIMARY KEY (full_name, flavor)
        ) WITHOUT ROWID;
        CREATE INDEX support_flavor_checked ON support(flavor, checked_at);

        CREATE TABLE details (
            full_name TEXT NOT NULL COLLATE NOCASE,
            flavor TEXT NOT NULL,
            readme TEXT,
            screenshots_json TEXT NOT NULL DEFAULT '[]',
            latest_version TEXT,
            latest_published_at REAL,
            latest_changelog TEXT,
            fetched_at REAL NOT NULL,
            PRIMARY KEY (full_name, flavor)
        );

        CREATE TABLE refresh_state (
            installation_id TEXT PRIMARY KEY,
            last_refresh_at REAL,
            updates_json TEXT
        );

        CREATE TABLE search_cache (
            query TEXT PRIMARY KEY,
            full_names TEXT NOT NULL,
            fetched_at REAL NOT NULL
        );

        CREATE TABLE rate_limit (
            resource TEXT PRIMARY KEY,
            remaining INTEGER,
            reset_at REAL,
            updated_at REAL NOT NULL
        );
        """,
        // 2: `classic` was split into vanilla, tbc, wrath, titan, cata and mists. Its rows
        // can't be told apart, and they're only a cache, so they go. `refresh_state` is keyed
        // by installation, and an installation's updates are recomputed on its next refresh.
        """
        DELETE FROM support WHERE flavor = 'classic';
        DELETE FROM details WHERE flavor = 'classic';
        """,
    ]
}

// MARK: - Rate limits

/// GitHub rate-limit state for one resource (`core` or `search`), shared by the app and CLI.
public struct RateLimitState: Sendable, Hashable {
    public var remaining: Int?
    public var resetAt: Date?

    public init(remaining: Int? = nil, resetAt: Date? = nil) {
        self.remaining = remaining
        self.resetAt = resetAt
    }

    /// True while no calls are left and the window hasn't reset.
    public func isExhausted(at now: Date) -> Bool {
        remaining == 0 && (resetAt.map { $0 > now } ?? false)
    }
}

extension MetadataDatabase {
    public func rateLimit(_ resource: String) -> RateLimitState? {
        guard let row = try? query("SELECT remaining, reset_at FROM rate_limit WHERE resource = ?", resource).first else { return nil }
        return RateLimitState(remaining: row.int(0), resetAt: row.date(1))
    }

    public func setRateLimit(_ resource: String, _ state: RateLimitState, at date: Date) {
        _ = try? execute("""
            INSERT INTO rate_limit(resource, remaining, reset_at, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(resource) DO UPDATE SET remaining = excluded.remaining, reset_at = excluded.reset_at, updated_at = excluded.updated_at
            WHERE (rate_limit.remaining, rate_limit.reset_at) IS NOT (excluded.remaining, excluded.reset_at)
            """, resource, state.remaining, state.resetAt, date)
    }
}
