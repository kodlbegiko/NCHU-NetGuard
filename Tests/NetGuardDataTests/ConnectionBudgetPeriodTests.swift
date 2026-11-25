import Foundation
import XCTest
import NetGuardData

final class ConnectionBudgetPeriodTests: XCTestCase {
    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }
    private func row(_ date: Date, id: UUID = UUID(), received: UInt64 = 10, sent: UInt64 = 5) throws -> SavedConnectionSession {
        try .init(id: id, label: "Hotspot", savedAt: date, received: received, sent: sent,
                  limitBytes: 1_000_000_000, intervals: 1)
    }
    func testMonthlyAnchorClampsInLeapAndNonLeapYears() throws {
        let leap = try ConnectionBudgetPeriod.monthly(at: date("2024-02-29T00:00:00Z"), anchorDay: 31, decimalGB: 5)
        XCTAssertEqual(leap.startDay, "2024-02-29")
        XCTAssertEqual(leap.endDay, "2024-03-30")
        let ordinary = try ConnectionBudgetPeriod.monthly(at: date("2025-02-27T00:00:00Z"), anchorDay: 31, decimalGB: 5)
        XCTAssertEqual(ordinary.startDay, "2025-01-31")
        XCTAssertEqual(ordinary.endDay, "2025-02-27")
    }
    func testTaipeiMidnightAndYearBoundary() throws {
        let before = try ConnectionBudgetPeriod.monthly(at: date("2026-12-31T15:59:59Z"), anchorDay: 1, decimalGB: 1)
        XCTAssertEqual(before.startDay, "2026-12-01")
        XCTAssertEqual(before.endDay, "2026-12-31")
        let after = try ConnectionBudgetPeriod.monthly(at: date("2026-12-31T16:00:00Z"), anchorDay: 1, decimalGB: 1)
        XCTAssertEqual(after.startDay, "2027-01-01")
        XCTAssertEqual(after.endDay, "2027-01-31")
    }
    func testExplicitSelectionAndInclusiveDateFilter() throws {
        let period = try ConnectionBudgetPeriod(startDay: "2026-11-01", endDay: "2026-11-30", decimalGB: 2)
        let first = try row(date("2026-10-31T16:00:00Z"), received: 1_000_000_000)
        let second = try row(date("2026-11-30T15:59:59Z"))
        let outside = try row(date("2026-11-30T16:00:00Z"))
        XCTAssertTrue(period.includes(first))
        XCTAssertTrue(period.includes(second))
        XCTAssertFalse(period.includes(outside))
        let rows = [first, second, outside]
        XCTAssertNil(try period.summarize(records: rows, selected: []))
        let reading = try XCTUnwrap(period.summarize(records: rows, selected: [first.id, second.id]))
        XCTAssertEqual(reading.recordCount, 2)
        XCTAssertEqual(reading.received, 1_000_000_010)
        XCTAssertEqual(reading.sent, 10)
        XCTAssertEqual(reading.remaining, 999_999_980)
        XCTAssertThrowsError(try period.summarize(records: rows, selected: [outside.id]))
        XCTAssertThrowsError(try period.summarize(records: rows, selected: [UUID()]))
    }
    func testInvalidDatesDuplicatesAndOverflow() throws {
        XCTAssertThrowsError(try ConnectionBudgetPeriod(startDay: "2026-11-31", endDay: "2026-12-01", decimalGB: 1))
        XCTAssertThrowsError(try ConnectionBudgetPeriod(startDay: "2026-12-01", endDay: "2026-11-01", decimalGB: 1))
        XCTAssertThrowsError(try ConnectionBudgetPeriod.monthly(at: Date(), anchorDay: 0, decimalGB: 1))
        let period = try ConnectionBudgetPeriod(startDay: "2026-11-01", endDay: "2026-11-30", decimalGB: 1)
        let timestamp = try date("2026-11-25T00:00:00Z")
        let a = try row(timestamp, received: UInt64.max, sent: 0)
        let b = try row(timestamp, received: 1, sent: 0)
        XCTAssertThrowsError(try period.summarize(records: [a, a], selected: [a.id]))
        XCTAssertThrowsError(try period.summarize(records: [a, b], selected: [a.id, b.id]))
        XCTAssertEqual(try period.summarize(records: [a], selected: [a.id])?.remaining, 0)
    }
}
