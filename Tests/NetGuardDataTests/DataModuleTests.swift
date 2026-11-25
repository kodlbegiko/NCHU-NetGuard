import Foundation
import XCTest
import NetGuardData

final class DataModuleTests: XCTestCase {
    func testStandaloneScopedHistoryAndBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("live.sqlite"))
        let day = try HistoryDay(day: "2026-11-24", total: 20, download: 15, upload: 5)
        try store.recordScoped(ScopedHistoryDay(aggregate: day, scopes: [.dorm: day]))
        let report = try HistoryAnalytics.period(endingBefore: "2026-11-25", days: 2,
                                                 records: store.recent(scope: .dorm))
        XCTAssertEqual(report.recordedDays, 1)
        XCTAssertEqual(report.rows.first?.record, nil)
        XCTAssertEqual(report.chartPoints.map(\.kind), [.missing, .download, .upload])
        XCTAssertTrue(report.csv(scope: .dorm).contains("2026-11-24,20,15,5,recorded,dorm"))
        let destination = directory.appendingPathComponent("backup.sqlite")
        try store.backup(to: destination)
        XCTAssertEqual(try HistoryBackupInspector.inspect(destination).classifiedRows, 1)
    }

    func testStandaloneDailyMigration() throws {
        let legacy = Data(#"{"date":"2026-11-25","today_in":20,"today_out":5}"#.utf8)
        let migrated = try UsageMigration.decode(legacy)
        XCTAssertEqual(migrated.dormIn, 20)
        XCTAssertEqual(migrated.dormOut, 5)
        XCTAssertEqual(migrated.measuredSampleCount, 0)
    }
}
