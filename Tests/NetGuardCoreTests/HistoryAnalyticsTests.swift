import XCTest
import NetGuardCore

final class HistoryAnalyticsTests: XCTestCase {
    func testCalendarWindowExcludesTodayAndMissingIsNotZero() throws {
        let report = try HistoryAnalytics.period(endingBefore: "2026-03-02", days: 3, records: [
            HistoryDay(day: "2026-02-27", total: 100, download: 80, upload: 20),
            HistoryDay(day: "2026-03-01", total: 0, download: 0, upload: 0),
            HistoryDay(day: "2026-03-02", total: 500, download: nil, upload: nil)
        ])
        XCTAssertEqual(report.rows.map(\.day), ["2026-02-27","2026-02-28","2026-03-01"])
        XCTAssertNil(report.rows[1].record)
        XCTAssertEqual(report.recordedDays, 2)
        XCTAssertEqual(report.averageBytes, 50)
    }
    func testCSVPreservesUnknownAndRecordedZero() throws {
        let report = try HistoryAnalytics.period(endingBefore: "2026-11-25", days: 3, records: [
            HistoryDay(day: "2026-11-22", total: 100, download: nil, upload: nil),
            HistoryDay(day: "2026-11-24", total: 0, download: 0, upload: 0)
        ])
        XCTAssertEqual(report.csv(), "date,total_bytes,download_bytes,upload_bytes,status\r\n2026-11-22,100,,,direction_unknown\r\n2026-11-23,,,,missing\r\n2026-11-24,0,0,0,recorded\r\n")
    }
    func testNoRecordsAndInvalidWindow() throws {
        let report = try HistoryAnalytics.period(endingBefore: "2026-11-25", days: 7, records: [])
        XCTAssertNil(report.averageBytes)
        XCTAssertThrowsError(try HistoryAnalytics.period(endingBefore: "2026-02-30", days: 7, records: []))
        XCTAssertThrowsError(try HistoryAnalytics.period(endingBefore: "2026-11-25", days: 0, records: []))
    }
    func testDuplicatesAreRejected() throws {
        let day = try HistoryDay(day: "2026-11-24", total: 1, download: nil, upload: nil)
        XCTAssertThrowsError(try HistoryAnalytics.period(endingBefore: "2026-11-25", days: 7, records: [day,day]))
    }
}
