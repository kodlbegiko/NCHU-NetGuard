import XCTest
import SQLite3
import NetGuardCore

final class HistoryBackupTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
    func testBackupPreservesAggregateAndScopes() throws {
        try withDirectory { dir in
            let source = try HistoryStore(url: dir.appendingPathComponent("live.sqlite"))
            let day = try HistoryDay(day: "2026-11-24", total: 10, download: 8, upload: 2)
            try source.recordScoped(ScopedHistoryDay(aggregate: day, scopes: [.dorm: day]))
            let backup = dir.appendingPathComponent("backup.sqlite")
            try source.backup(to: backup)
            let summary = try HistoryBackupInspector.inspect(backup)
            XCTAssertEqual(summary.schemaVersion, 2)
            XCTAssertEqual(summary.recordedDays, 1)
            XCTAssertEqual(summary.classifiedRows, 1)
            let restored = try HistoryStore(url: backup)
            XCTAssertEqual(try restored.recent(scope: .dorm), [day])
        }
    }
    func testExistingDestinationIsNeverOverwritten() throws {
        try withDirectory { dir in
            let source = try HistoryStore(url: dir.appendingPathComponent("live.sqlite"))
            let destination = dir.appendingPathComponent("existing.sqlite")
            let original = Data("keep me".utf8)
            try original.write(to: destination)
            XCTAssertThrowsError(try source.backup(to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }
    func testInvalidFileFailsReadOnlyPreflight() throws {
        try withDirectory { dir in
            let url = dir.appendingPathComponent("bad.sqlite")
            let bytes = Data("not sqlite".utf8)
            try bytes.write(to: url)
            XCTAssertThrowsError(try HistoryBackupInspector.inspect(url))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    func testInconsistentScopeTotalIsRejected() throws {
        try withDirectory { dir in
            let url = dir.appendingPathComponent("bad.sqlite")
            do {
                let store = try HistoryStore(url: url)
                try store.upsert(HistoryDay(day: "2026-11-24", total: 10, download: 8, upload: 2))
            }
            var db: OpaquePointer?
            guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
                throw HistoryStoreError.database("fixture open")
            }
            let result = sqlite3_exec(db, "INSERT INTO history_scopes VALUES('2026-11-24','dorm',1,1)", nil, nil, nil)
            sqlite3_close(db)
            XCTAssertEqual(result, SQLITE_OK)
            XCTAssertThrowsError(try HistoryBackupInspector.inspect(url))
        }
    }
}
