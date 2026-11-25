import Foundation
#if SWIFT_PACKAGE
import NetGuardTraffic
#endif
import CoreFoundation
import SQLite3
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Canonicalize the caller-owned parent (macOS /var and /tmp may be
/// system symlinks). Never resolve the final database filename: SQLite
/// NOFOLLOW must still reject a symlink at the actual data boundary.
enum HistorySQLitePath {
    static func resolve(_ url: URL) throws -> String {
        guard url.isFileURL, !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".", url.lastPathComponent != "..",
              let parent = realpath(url.deletingLastPathComponent().path, nil)
        else { throw HistoryStoreError.database("invalid database path") }
        defer { free(parent) }
        return String(cString: parent) + "/" + url.lastPathComponent
    }
}

public enum HistoryStoreError: Error, Equatable {
    case invalidRecord, invalidLegacy, unsupportedSchema, database(String)
}

public struct HistoryDay: Codable, Equatable, Sendable {
    public let day: String
    public let total: UInt64
    public let download: UInt64?
    public let upload: UInt64?

    private enum CodingKeys: String, CodingKey { case day, total, download, upload }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(day: v.decode(String.self, forKey: .day), total: v.decode(UInt64.self, forKey: .total),
                      download: v.decodeIfPresent(UInt64.self, forKey: .download),
                      upload: v.decodeIfPresent(UInt64.self, forKey: .upload))
    }

    public init(day: String, total: UInt64, download: UInt64?, upload: UInt64?) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard let date = f.date(from: day), f.string(from: date) == day,
              total <= UInt64(Int64.max),
              (download == nil) == (upload == nil) else { throw HistoryStoreError.invalidRecord }
        if let download, let upload {
            let (sum, overflow) = download.addingReportingOverflow(upload)
            guard !overflow, sum == total else { throw HistoryStoreError.invalidRecord }
        }
        self.day = day
        self.total = total
        self.download = download
        self.upload = upload
    }
}

/// Legacy total-only records retain an unknown directional breakdown.
public enum LegacyHistoryMigration {
    public static func decode(_ data: Data) throws -> [HistoryDay] {
        guard data.count <= 4 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count <= 36_600
        else { throw HistoryStoreError.invalidLegacy }
        func bytes(_ value: Any?) throws -> UInt64 {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0,
                  n.doubleValue <= 9_007_199_254_740_991,
                  n.doubleValue.rounded(.towardZero) == n.doubleValue
            else { throw HistoryStoreError.invalidLegacy }
            return UInt64(n.doubleValue)
        }
        return try object.keys.sorted().map { day in
            if let record = object[day] as? [String: Any] {
                let total = try bytes(record["total"])
                let dl = record["dl"] == nil ? nil : try bytes(record["dl"])
                let ul = record["ul"] == nil ? nil : try bytes(record["ul"])
                return try HistoryDay(day: day, total: total, download: dl, upload: ul)
            }
            return try HistoryDay(day: day, total: bytes(object[day]), download: nil, upload: nil)
        }
    }
}

/// Scope rows represent observed bytes, not a complete day or verified
/// campus billing. A missing scope row must never be interpreted as zero.
public struct ScopedHistoryDay: Equatable, Sendable {
    public let aggregate: HistoryDay
    public let scopes: [NetworkScope: HistoryDay]
    public init(aggregate: HistoryDay, scopes: [NetworkScope: HistoryDay]) throws {
        _ = try HistoryDay(day: aggregate.day, total: aggregate.total,
                           download: aggregate.download, upload: aggregate.upload)
        guard let expectedDownload = aggregate.download, let expectedUpload = aggregate.upload
        else { throw HistoryStoreError.invalidRecord }
        var download: UInt64 = 0
        var upload: UInt64 = 0
        for (scope, record) in scopes {
            _ = try HistoryDay(day: record.day, total: record.total,
                               download: record.download, upload: record.upload)
            guard record.day == aggregate.day, scope != .unknown || record.total > 0,
                  let dl = record.download, let ul = record.upload else { throw HistoryStoreError.invalidRecord }
            let (d, od) = download.addingReportingOverflow(dl)
            let (u, ou) = upload.addingReportingOverflow(ul)
            guard !od, !ou else { throw HistoryStoreError.invalidRecord }
            download = d; upload = u
        }
        guard download == expectedDownload, upload == expectedUpload else { throw HistoryStoreError.invalidRecord }
        self.aggregate = aggregate
        self.scopes = scopes
    }
}

/// Local SQLite store. Confine each instance to one serial caller. No network,
/// external packages or telemetry. Schema upgrades fail closed.
public final class HistoryStore {
    private var db: OpaquePointer?
    public init(url: URL) throws {
        guard url.isFileURL else { throw HistoryStoreError.database("invalid history URL") }
        let rc = sqlite3_open_v2(try HistorySQLitePath.resolve(url), &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard rc == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw HistoryStoreError.database("open")
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA trusted_schema=OFF")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA synchronous=FULL")
            // Read schema version only after acquiring the write transaction.
            // A second initializer must observe the first one's committed migration.
            try transaction {
                let version = try scalar("PRAGMA user_version")
                guard (0...3).contains(version) else { throw HistoryStoreError.unsupportedSchema }
                try validateTableInventory(version: version)
                if version == 0 {
                    try execute("CREATE TABLE history_days(day TEXT PRIMARY KEY, total INTEGER NOT NULL CHECK(total >= 0), download INTEGER, upload INTEGER, CHECK((download IS NULL AND upload IS NULL) OR (download IS NOT NULL AND upload IS NOT NULL AND download >= 0 AND upload >= 0 AND download + upload = total)))")
                }
                if version < 3 {
                    // v3 permits an affirmative measured-zero row for known scopes.
                    // Rebuild v2 atomically; absence stays absent and no zero is inferred.
                    if version == 2 {
                        try execute("ALTER TABLE history_scopes RENAME TO history_scopes_v2")
                    }
                    try execute("CREATE TABLE history_scopes(day TEXT NOT NULL REFERENCES history_days(day), scope TEXT NOT NULL CHECK(scope IN ('dorm','campusWifi','external','unknown')), download INTEGER NOT NULL CHECK(typeof(download)='integer' AND download >= 0), upload INTEGER NOT NULL CHECK(typeof(upload)='integer' AND upload >= 0), CHECK(scope <> 'unknown' OR download > 0 OR upload > 0), PRIMARY KEY(day,scope))")
                    if version == 2 {
                        try execute("INSERT INTO history_scopes SELECT day,scope,download,upload FROM history_scopes_v2")
                        try execute("DROP TABLE history_scopes_v2")
                    }
                    try execute("PRAGMA user_version=3")
                }
                try validateTableInventory(version: 3)
            }
            // No schema mutation or journal mode change before validating the inventory.
            try execute("PRAGMA journal_mode=DELETE")
        } catch {
            if let db { sqlite3_close(db) }
            db = nil
            throw error
        }
    }
    deinit { if let db { sqlite3_close(db) } }

    /// Snapshot using SQLite's backup API, never by copying a live DB file.
    /// The destination must not exist. The caller owns its parent directory.
    public func backup(to destination: URL) throws {
        guard let db else { throw HistoryStoreError.database("backup source") }
        try Self.backup(source: db, to: destination)
    }

    /// Independent read-only source connection for a background user export.
    public static func backup(from source: URL, to destination: URL) throws {
        guard source.isFileURL else { throw HistoryStoreError.database("backup source") }
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(try HistorySQLitePath.resolve(source), &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw HistoryStoreError.database("backup source open")
        }
        defer { sqlite3_close(connection) }
        try backup(source: connection, to: destination)
    }

    private static func backup(source db: OpaquePointer, to destination: URL) throws {
        guard destination.isFileURL else { throw HistoryStoreError.database("backup destination") }
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".netguard-backup-" + UUID().uuidString)
        guard !fm.fileExists(atPath: destination.path),
              fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw HistoryStoreError.database("backup destination exists or unavailable") }
        defer { try? fm.removeItem(at: temporary) }
        var target: OpaquePointer?
        let open = sqlite3_open_v2(try HistorySQLitePath.resolve(temporary), &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard open == SQLITE_OK, let target else {
            if let target { sqlite3_close(target) }
            throw HistoryStoreError.database("backup open")
        }
        guard let operation = sqlite3_backup_init(target, "main", db, "main") else {
            sqlite3_close(target)
            throw HistoryStoreError.database("backup init")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var step: Int32
        repeat {
            step = sqlite3_backup_step(operation, 128)
            if step == SQLITE_BUSY || step == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.01) }
        } while (step == SQLITE_OK || step == SQLITE_BUSY || step == SQLITE_LOCKED) &&
                ProcessInfo.processInfo.systemUptime < deadline
        let finish = sqlite3_backup_finish(operation)
        let close = sqlite3_close(target)
        guard step == SQLITE_DONE, finish == SQLITE_OK, close == SQLITE_OK
        else { throw HistoryStoreError.database("backup incomplete") }
        _ = try HistoryBackupInspector.inspect(temporary)
        // moveItem refuses an existing destination, including a race after the initial check.
        try fm.moveItem(at: temporary, to: destination)
    }

    /// Reject views, triggers, virtual tables and foreign table inventories.
    /// Older v1 fixtures need not have today's CHECK clauses. Column names
    /// and primary-key positions must nevertheless match the supported model.
    private func validateTableInventory(version: Int64) throws {
        let expected = version == 0 ? 0 : (version == 1 ? 1 : 2)
        guard try scalar("SELECT count(*) FROM sqlite_master WHERE type IN ('view','trigger')") == 0,
              try scalar("SELECT count(*) FROM sqlite_master WHERE type='table'") == expected,
              try scalar("SELECT count(*) FROM pragma_table_list WHERE schema='main' AND name IN ('history_days','history_scopes') AND type='table'") == expected
        else { throw HistoryStoreError.database("unexpected history schema") }
        if version >= 1 {
            guard try scalar("SELECT count(*) FROM pragma_table_info('history_days')") == 4,
                  try scalar("SELECT count(*) FROM pragma_table_info('history_days') WHERE (cid=0 AND name='day' AND type='TEXT' AND pk=1) OR (cid=1 AND name='total' AND type='INTEGER' AND pk=0) OR (cid=2 AND name='download' AND type='INTEGER' AND pk=0) OR (cid=3 AND name='upload' AND type='INTEGER' AND pk=0)") == 4,
                  try scalar("SELECT count(*) FROM pragma_table_xinfo('history_days')") == 4
            else { throw HistoryStoreError.database("unexpected history days columns") }
        }
        if version >= 2 {
            guard try scalar("SELECT count(*) FROM pragma_table_info('history_scopes')") == 4,
                  try scalar("SELECT count(*) FROM pragma_table_info('history_scopes') WHERE (cid=0 AND name='day' AND type='TEXT' AND pk=1) OR (cid=1 AND name='scope' AND type='TEXT' AND pk=2) OR (cid=2 AND name='download' AND type='INTEGER' AND pk=0) OR (cid=3 AND name='upload' AND type='INTEGER' AND pk=0)") == 4,
                  try scalar("SELECT count(*) FROM pragma_table_xinfo('history_scopes')") == 4
            else { throw HistoryStoreError.database("unexpected history scope columns") }
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        else { throw HistoryStoreError.database("execute") }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt
        else { throw HistoryStoreError.database("prepare") }
        return stmt
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw HistoryStoreError.database("scalar") }
        return sqlite3_column_int64(stmt, 0)
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func write(_ day: HistoryDay, replace: Bool) throws {
        _ = try HistoryDay(day: day.day, total: day.total, download: day.download, upload: day.upload)
        let sql = replace
            ? "INSERT INTO history_days VALUES(?,?,?,?) ON CONFLICT(day) DO UPDATE SET total=excluded.total,download=excluded.download,upload=excluded.upload"
            : "INSERT INTO history_days VALUES(?,?,?,?) ON CONFLICT(day) DO NOTHING"
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, day.day, -1, transient) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 2, Int64(day.total)) == SQLITE_OK,
              (day.download.map { sqlite3_bind_int64(stmt, 3, Int64($0)) } ?? sqlite3_bind_null(stmt, 3)) == SQLITE_OK,
              (day.upload.map { sqlite3_bind_int64(stmt, 4, Int64($0)) } ?? sqlite3_bind_null(stmt, 4)) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.database("write") }
    }
    private func clearScopes(day: String) throws {
        let stmt = try statement("DELETE FROM history_scopes WHERE day=?")
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, day, -1, transient) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.database("clear scopes") }
    }

    public func upsert(_ day: HistoryDay) throws {
        try transaction {
            try write(day, replace: true)
            try clearScopes(day: day.day)
        }
    }

    /// Atomically store aggregate and explicitly observed scope rows. Existing
    /// finalized history wins during stale-state recovery; no retroactive split.
    public func recordScoped(_ record: ScopedHistoryDay, preserveExisting: Bool = false) throws {
        _ = try ScopedHistoryDay(aggregate: record.aggregate, scopes: record.scopes)
        try transaction {
            try write(record.aggregate, replace: !preserveExisting)
            if preserveExisting && sqlite3_changes(db) == 0 { return }
            try clearScopes(day: record.aggregate.day)
            let stmt = try statement("INSERT INTO history_scopes(day,scope,download,upload) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (scope, day) in record.scopes {
                guard let dl = day.download, let ul = day.upload,
                      sqlite3_bind_text(stmt, 1, day.day, -1, transient) == SQLITE_OK,
                      sqlite3_bind_text(stmt, 2, scope.rawValue, -1, transient) == SQLITE_OK,
                      sqlite3_bind_int64(stmt, 3, Int64(dl)) == SQLITE_OK,
                      sqlite3_bind_int64(stmt, 4, Int64(ul)) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.database("write scope") }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
            }
        }
    }

    /// Crash recovery of a stale prior-day state must not replace finalized history.
    public func insertIfAbsent(_ day: HistoryDay) throws { try write(day, replace: false) }

    /// Import is atomic and idempotent. Existing database days win over legacy data.
    public func importLegacy(_ data: Data) throws {
        let days = try LegacyHistoryMigration.decode(data)
        try transaction { for day in days { try write(day, replace: false) } }
    }
    public func recent(limit: Int = 30, scope: NetworkScope? = nil) throws -> [HistoryDay] {
        guard (1...3660).contains(limit) else { throw HistoryStoreError.invalidRecord }
        let sql = scope == nil
            ? "SELECT day,total,download,upload FROM history_days ORDER BY day DESC LIMIT ?"
            : "SELECT day,download+upload,download,upload FROM history_scopes WHERE scope=? ORDER BY day DESC LIMIT ?"
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        var limitIndex: Int32 = 1
        if let scope {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(stmt, 1, scope.rawValue, -1, transient) == SQLITE_OK
            else { throw HistoryStoreError.database("bind scope") }
            limitIndex = 2
        }
        guard sqlite3_bind_int64(stmt, limitIndex, Int64(limit)) == SQLITE_OK else { throw HistoryStoreError.database("bind") }
        var result: [HistoryDay] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return result }
            guard rc == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0)
            else { throw HistoryStoreError.database("read") }
            func value(_ col: Int32) throws -> UInt64? {
                if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
                guard sqlite3_column_type(stmt, col) == SQLITE_INTEGER,
                      sqlite3_column_int64(stmt, col) >= 0 else { throw HistoryStoreError.invalidRecord }
                return UInt64(sqlite3_column_int64(stmt, col))
            }
            guard let total = try value(1) else { throw HistoryStoreError.invalidRecord }
            result.append(try HistoryDay(day: String(cString: text), total: total,
                                         download: value(2), upload: value(3)))
        }
    }
}
