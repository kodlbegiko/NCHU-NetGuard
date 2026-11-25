import XCTest
import SQLite3
@testable import NetGuardCore

final class HistoryStoreTests: XCTestCase {
    func withURL(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("history.sqlite"))
    }
    func testPersistenceAndOrdering() throws {
        try withURL { url in
            let day = try HistoryDay(day: "2026-11-25", total: 10, download: 8, upload: 2)
            do {
                let store = try HistoryStore(url: url)
                try store.upsert(day)
                try store.upsert(HistoryDay(day: "2026-11-24", total: 5, download: nil, upload: nil))
            }
            let reopened = try HistoryStore(url: url)
            XCTAssertEqual(try reopened.recent(limit: 1), [day])
            XCTAssertEqual(try reopened.recent().count, 2)
        }
    }
    func testLegacyImportIsIdempotentAndDoesNotInventDirections() throws {
        try withURL { url in
            let store = try HistoryStore(url: url)
            let raw = Data(#"{"2026-11-24":100,"2026-11-25":{"total":10,"dl":7,"ul":3}}"#.utf8)
            try store.importLegacy(raw)
            try store.upsert(HistoryDay(day: "2026-11-25", total: 20, download: 15, upload: 5))
            try store.importLegacy(raw)
            let rows = try store.recent()
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0].total, 20)
            XCTAssertNil(rows[1].download)
            XCTAssertNil(rows[1].upload)
        }
    }
    func testMalformedImportLeavesExistingData() throws {
        try withURL { url in
            let store = try HistoryStore(url: url)
            try store.importLegacy(Data(#"{"2026-11-24":100}"#.utf8))
            XCTAssertThrowsError(try store.importLegacy(Data(#"{"2026-11-23":50,"2026-11-25":-1}"#.utf8)))
            XCTAssertEqual(try store.recent().map(\.day), ["2026-11-24"])
        }
    }
    func testRejectsInvalidDateAndBreakdown() {
        XCTAssertThrowsError(try HistoryDay(day: "2026-02-30", total: 1, download: nil, upload: nil))
        XCTAssertThrowsError(try HistoryDay(day: "2026-11-25", total: 10, download: 8, upload: 8))
        XCTAssertThrowsError(try HistoryDay(day: "2026-11-25", total: 10, download: 8, upload: nil))
    }

    func testStaleDailyRecoveryCannotOverwriteFinalizedHistory() throws {
        try withURL { url in
            let store = try HistoryStore(url: url)
            let final = try HistoryDay(day: "2026-11-24", total: 100, download: 80, upload: 20)
            try store.upsert(final)
            try store.insertIfAbsent(HistoryDay(day: "2026-11-24", total: 10, download: 8, upload: 2))
            XCTAssertEqual(try store.recent(), [final])
        }
    }


    func testScopedRecordsPersistWithoutInventingLegacyScope() throws {
        try withURL { url in
            let store = try HistoryStore(url: url)
            try store.importLegacy(Data(#"{"2026-11-23":20}"#.utf8))
            let aggregate = try HistoryDay(day: "2026-11-24", total: 100, download: 70, upload: 30)
            let dorm = try HistoryDay(day: aggregate.day, total: 80, download: 60, upload: 20)
            let unknown = try HistoryDay(day: aggregate.day, total: 20, download: 10, upload: 10)
            try store.recordScoped(ScopedHistoryDay(aggregate: aggregate, scopes: [.dorm: dorm, .unknown: unknown]))
            XCTAssertEqual(try store.recent(scope: .dorm), [dorm])
            XCTAssertEqual(try store.recent(scope: .unknown), [unknown])
            XCTAssertTrue(try store.recent(scope: .external).isEmpty)
            XCTAssertEqual(try HistoryStore(url: url).recent().count, 2)
            try store.insertIfAbsent(aggregate)
            XCTAssertEqual(try store.recent(scope: .dorm), [dorm])
            try store.upsert(aggregate)
            XCTAssertTrue(try store.recent(scope: .dorm).isEmpty)
        }
    }

    func testScopedSumAndDayMustMatch() throws {
        let total = try HistoryDay(day: "2026-11-24", total: 100, download: 80, upload: 20)
        XCTAssertThrowsError(try ScopedHistoryDay(aggregate: total, scopes: [:]))
        let wrongDay = try HistoryDay(day: "2026-11-23", total: 100, download: 80, upload: 20)
        XCTAssertThrowsError(try ScopedHistoryDay(aggregate: total, scopes: [.dorm: wrongDay]))
    }


    func testRejectsUnrecognizedSchemaWithoutMigration() throws {
        try withURL { url in
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
            guard let database else { throw HistoryStoreError.database("fixture") }
            XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE unrelated(value TEXT); INSERT INTO unrelated VALUES('preserve');", nil, nil, nil), SQLITE_OK)
            sqlite3_close(database)
            XCTAssertThrowsError(try HistoryStore(url: url))
            var reopened: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(url.path, &reopened, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            defer { sqlite3_close(reopened) }
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(reopened, "SELECT value FROM unrelated", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "preserve")
        }
    }
    func testCanonicalParentDoesNotResolveFinalDatabaseSymlink() throws {
        try withURL { url in
            let target = url.deletingLastPathComponent()
            let alias = target.appendingPathComponent("parent-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            let viaAlias = alias.appendingPathComponent("history.sqlite")
            let store = try HistoryStore(url: viaAlias)
            try store.upsert(HistoryDay(day: "2026-11-25", total: 2, download: nil, upload: nil))
            XCTAssertEqual(try HistoryStore(url: url).recent().first?.total, 2)
            let link = alias.appendingPathComponent("linked.sqlite")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            XCTAssertThrowsError(try HistoryStore(url: link))
        }
    }
    func testHistoryRejectsSymlink() throws {
        try withURL { url in
            let target = url.deletingLastPathComponent().appendingPathComponent("target.sqlite")
            let store = try HistoryStore(url: target)
            try store.upsert(HistoryDay(day: "2026-11-25", total: 1, download: nil, upload: nil))
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            XCTAssertThrowsError(try HistoryStore(url: url))
            XCTAssertThrowsError(try HistoryBackupInspector.inspect(url))
            XCTAssertEqual(try store.recent().first?.total, 1)
        }
    }
    func testConcurrentInitializationUsesSingleMigration() throws {
        try withURL { url in
            let lock = NSLock()
            var failures: [String] = []
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                do {
                    let store = try HistoryStore(url: url)
                    _ = try store.recent()
                } catch {
                    lock.lock()
                    failures.append(String(describing: error))
                    lock.unlock()
                }
            }
            XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
            XCTAssertTrue(try HistoryStore(url: url).recent().isEmpty)
        }
    }
    func testActualV1DatabaseMigratesWithoutReclassification() throws {
        try withURL { url in
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
            guard let database else { throw HistoryStoreError.database("fixture") }
            let sql = "CREATE TABLE history_days(day TEXT PRIMARY KEY, total INTEGER NOT NULL, download INTEGER, upload INTEGER); INSERT INTO history_days VALUES('2026-11-24',100,80,20); PRAGMA user_version=1;"
            let status = sqlite3_exec(database, sql, nil, nil, nil)
            sqlite3_close(database)
            XCTAssertEqual(status, SQLITE_OK)
            let store = try HistoryStore(url: url)
            XCTAssertEqual(try store.recent().first?.total, 100)
            for scope in NetworkScope.allCases {
                XCTAssertTrue(try store.recent(scope: scope).isEmpty)
            }
        }
    }

}
