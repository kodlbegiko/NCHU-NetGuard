import Foundation
import CoreFoundation
import SQLite3

public enum HistoryStoreError: Error, Equatable {
    case invalidRecord, invalidLegacy, unsupportedSchema, database(String)
}

public struct HistoryDay: Codable, Equatable, Sendable {
    public let day: String
    public let total: UInt64
    public let download: UInt64?
    public let upload: UInt64?

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
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
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
        for record in scopes.values {
            _ = try HistoryDay(day: record.day, total: record.total,
                               download: record.download, upload: record.upload)
            guard record.day == aggregate.day, record.total > 0,
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
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw HistoryStoreError.database("open")
        }
        do {
            sqlite3_busy_timeout(db, 1000)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            let version = try scalar("PRAGMA user_version")
            guard (0...2).contains(version) else { throw HistoryStoreError.unsupportedSchema }
            if version == 0 {
                try transaction {
                    try execute("CREATE TABLE history_days(day TEXT PRIMARY KEY, total INTEGER NOT NULL CHECK(total >= 0), download INTEGER, upload INTEGER, CHECK((download IS NULL AND upload IS NULL) OR (download IS NOT NULL AND upload IS NOT NULL AND download >= 0 AND upload >= 0 AND download + upload = total)))")
                    try execute("PRAGMA user_version=1")
                }
            }
            if version < 2 {
                try transaction {
                    try execute("CREATE TABLE history_scopes(day TEXT NOT NULL REFERENCES history_days(day), scope TEXT NOT NULL CHECK(scope IN ('dorm','campusWifi','external','unknown')), download INTEGER NOT NULL CHECK(download >= 0), upload INTEGER NOT NULL CHECK(upload >= 0), CHECK(download + upload > 0), PRIMARY KEY(day,scope))")
                    try execute("PRAGMA user_version=2")
                }
            }
            try execute("PRAGMA foreign_keys=ON")
        } catch {
            if let db { sqlite3_close(db) }
            db = nil
            throw error
        }
    }
    deinit { if let db { sqlite3_close(db) } }

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

    /// Atomically store aggregate and nonzero observed scope rows. Existing
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
