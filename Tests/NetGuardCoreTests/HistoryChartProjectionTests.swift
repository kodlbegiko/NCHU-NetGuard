import XCTest
import NetGuardCore

final class HistoryChartProjectionTests: XCTestCase {
    func testPointsPreserveMissingZeroAndLegacyTotal() throws {
        let period = try HistoryAnalytics.period(endingBefore: "2026-11-25", days: 5, records: [
            HistoryDay(day: "2026-11-20", total: 100, download: 70, upload: 30),
            HistoryDay(day: "2026-11-22", total: 0, download: 0, upload: 0),
            HistoryDay(day: "2026-11-23", total: 12, download: nil, upload: nil),
            HistoryDay(day: "2026-11-24", total: 0, download: nil, upload: nil)
        ])
        XCTAssertEqual(period.chartPoints.map(\.kind), [.download, .upload, .missing, .recordedZero, .directionUnknown, .directionUnknown])
        XCTAssertEqual(period.chartPoints.map(\.bytes), [70, 30, 0, 0, 12, 0])
        XCTAssertEqual(Set(period.chartPoints.map(\.id)).count, period.chartPoints.count)
    }
    func testSingleDirectionHasNoInventedBar() throws {
        let period = try HistoryAnalytics.period(endingBefore: "2026-11-25", days: 1, records: [
            HistoryDay(day: "2026-11-24", total: 99, download: 0, upload: 99)
        ])
        XCTAssertEqual(period.chartPoints.map(\.kind), [.upload])
    }
}
