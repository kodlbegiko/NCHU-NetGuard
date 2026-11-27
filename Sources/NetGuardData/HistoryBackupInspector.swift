import Foundation
#if SWIFT_PACKAGE
import NetGuardTraffic
#endif
import SQLite3

public struct HistoryBackupSummary: Equatable, Sendable {
    public let schemaVersion: Int
    public let recordedDays: Int
    public let classifiedRows: Int
}

/// Read-only preflight, not an import or a proof of backup provenance.
/// A successful result never grants permission to replace the active store.
public enum HistoryBackupInspector {
    public static func inspect(_ url: URL) throws -> HistoryBackupSummary {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= 64 * 1024 * 1024
        else { throw HistoryStoreError.database("invalid backup file") }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(try HistorySQLitePath.resolve(url), &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK, let db = database else {
            if let database { sqlite3_close(database) }
            throw HistoryStoreError.database("backup read")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        // Bound attacker-controlled query work as well as the file size.
        var deadline = ProcessInfo.processInfo.systemUptime + 5
        return try withUnsafeMutablePointer(to: &deadline) { context in
        sqlite3_progress_handler(db, 1000, { opaque in
            guard let opaque else { return 1 }
            return ProcessInfo.processInfo.systemUptime >= opaque.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
        }, UnsafeMutableRawPointer(context))
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK
        else { throw HistoryStoreError.database("backup read-only setup") }
        // All schema, integrity and semantic checks see one read snapshot.
        // This is not a simultaneous snapshot of the other history stores.
        defer { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        func query(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement
            else { throw HistoryStoreError.database("backup schema") }
            defer { sqlite3_finalize(statement) }
            try body(statement)
        }
        func scalar(_ sql: String) throws -> Int {
            var value = 0
            try query(sql) { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) == SQLITE_INTEGER,
                      let n = Int(exactly: sqlite3_column_int64(stmt, 0)), n >= 0,
                      sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.invalidRecord }
                value = n
            }
            return value
        }
        let version = try scalar("PRAGMA user_version")
        guard (1...3).contains(version) else { throw HistoryStoreError.unsupportedSchema }
        try query("PRAGMA quick_check") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let text = sqlite3_column_text(stmt, 0), String(cString: text) == "ok",
                  sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.database("backup integrity") }
        }
        try query("PRAGMA foreign_key_check") { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.database("backup foreign key") }
        }
        // Inspect actual tables only, not attacker-defined views.
        let expected = version == 1 ? 1 : 2
        guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('history_days','history_scopes')") == expected,
              try scalar("SELECT count(*) FROM sqlite_master WHERE type IN ('view','trigger')") == 0,
              try scalar("SELECT count(*) FROM sqlite_master WHERE type='table'") == expected
        else { throw HistoryStoreError.database("backup unexpected schema") }
        guard try scalar("SELECT count(*) FROM pragma_table_list WHERE schema='main' AND name IN ('history_days','history_scopes') AND type='table'") == expected,
              try scalar("SELECT count(*) FROM pragma_table_xinfo('history_days')") == 4,
              try scalar("SELECT count(*) FROM pragma_table_info('history_days') WHERE (cid=0 AND name='day' AND type='TEXT' AND pk=1) OR (cid=1 AND name='total' AND type='INTEGER' AND pk=0) OR (cid=2 AND name='download' AND type='INTEGER' AND pk=0) OR (cid=3 AND name='upload' AND type='INTEGER' AND pk=0)") == 4
        else { throw HistoryStoreError.database("backup unexpected columns") }
        if version >= 2 {
            guard try scalar("SELECT count(*) FROM pragma_table_xinfo('history_scopes')") == 4,
                  try scalar("SELECT count(*) FROM pragma_table_info('history_scopes') WHERE (cid=0 AND name='day' AND type='TEXT' AND pk=1) OR (cid=1 AND name='scope' AND type='TEXT' AND pk=2) OR (cid=2 AND name='download' AND type='INTEGER' AND pk=0) OR (cid=3 AND name='upload' AND type='INTEGER' AND pk=0)") == 4
            else { throw HistoryStoreError.database("backup unexpected scope columns") }
        }
        let count = try scalar("SELECT count(*) FROM history_days")
        guard count <= 36_600 else { throw HistoryStoreError.invalidRecord }
        var days: [String: HistoryDay] = [:]
        try query("SELECT day,total,download,upload FROM history_days") { stmt in
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw HistoryStoreError.invalidRecord }
                let day = try HistorySQLiteText.read(stmt, 0, length: 10...10)
                func value(_ col: Int32) throws -> UInt64? {
                    if sqlite3_column_type(stmt,col) == SQLITE_NULL { return nil }
                    guard sqlite3_column_type(stmt,col) == SQLITE_INTEGER,
                          let n = UInt64(exactly: sqlite3_column_int64(stmt,col)) else { throw HistoryStoreError.invalidRecord }
                    return n
                }
                guard let total = try value(1) else { throw HistoryStoreError.invalidRecord }
                let record = try HistoryDay(day: day, total: total, download: value(2), upload: value(3))
                guard days.updateValue(record, forKey: day) == nil else { throw HistoryStoreError.invalidRecord }
            }
        }
        guard days.count == count else { throw HistoryStoreError.invalidRecord }
        var classified = 0
        if version >= 2 {
            var byDay: [String: [NetworkScope: HistoryDay]] = [:]
            try query("SELECT day,scope,download,upload FROM history_scopes") { stmt in
                while true {
                    let rc = sqlite3_step(stmt)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW, classified < count * 4,
                          let scope = NetworkScope(rawValue: try HistorySQLiteText.read(stmt, 1, length: 1...10)),
                          sqlite3_column_type(stmt,2) == SQLITE_INTEGER, sqlite3_column_type(stmt,3) == SQLITE_INTEGER,
                          let dl = UInt64(exactly: sqlite3_column_int64(stmt,2)),
                          let ul = UInt64(exactly: sqlite3_column_int64(stmt,3))
                    else { throw HistoryStoreError.invalidRecord }
                    let day = try HistorySQLiteText.read(stmt, 0, length: 10...10)
                    let (total, overflow) = dl.addingReportingOverflow(ul)
                    guard !overflow, days[day] != nil, version >= 3 || total > 0 else { throw HistoryStoreError.invalidRecord }
                    let row = try HistoryDay(day: day, total: total, download: dl, upload: ul)
                    guard byDay[day, default: [:]].updateValue(row, forKey: scope) == nil else { throw HistoryStoreError.invalidRecord }
                    classified += 1
                }
            }
            for (day, scopes) in byDay {
                guard let aggregate = days[day] else { throw HistoryStoreError.invalidRecord }
                _ = try ScopedHistoryDay(aggregate: aggregate, scopes: scopes)
            }
        }
        return HistoryBackupSummary(schemaVersion: version, recordedDays: count, classifiedRows: classified)
        }
    }
}
