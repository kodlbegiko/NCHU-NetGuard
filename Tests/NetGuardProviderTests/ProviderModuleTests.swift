import Foundation
import XCTest
import NetGuardProvider

final class ProviderModuleTests: XCTestCase {
    func testInvalidFreshnessWindowFailsClosed() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z"))
        let observation = ProviderObservation(status: .listed, requestedDate: "2026-11-25",
            retrievedAt: "2026-11-25T12:00:00Z", rank: 1, downloadDisplay: "1 GB",
            uploadDisplay: "1 GB", totalDisplay: "2 GB", unitsVerified: false)
        for age in [Double.nan, Double.infinity, -1] {
            XCTAssertFalse(observation.isFresh(for: "2026-11-25", now: now, maxAge: age))
        }
    }
    func testSingleFlightAndBackoffSurviveInvalidation() throws {
        var gate = ProviderPollGate()
        let first = try XCTUnwrap(gate.begin(at: 0))
        gate.invalidate()
        XCTAssertNil(gate.begin(at: 100))
        XCTAssertFalse(gate.finish(UUID(), usable: true))
        XCTAssertFalse(gate.finish(first, usable: true))
        XCTAssertNil(gate.begin(at: 59))
        let second = try XCTUnwrap(gate.begin(at: 60))
        XCTAssertTrue(gate.finish(second, usable: false))
        XCTAssertNil(gate.begin(at: 179))
        let third = try XCTUnwrap(gate.begin(at: 180))
        XCTAssertTrue(gate.finish(third, usable: true))
        XCTAssertNil(gate.begin(at: 239))
        XCTAssertNotNil(gate.begin(at: 240))
    }
    func testInvalidRankingNeverCountsAsUsable() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z"))
        for (rank, text, units) in [(0, "1 GB", false), (1, "1\nGB", false), (1, "1 GB", true), (1, String(repeating: "9", count: 100), false)] {
            let observation = ProviderObservation(status: .listed, requestedDate: "2026-11-25",
                retrievedAt: "2026-11-25T12:00:00Z", rank: rank, downloadDisplay: text,
                uploadDisplay: "1 GB", totalDisplay: "2 GB", unitsVerified: units)
            XCTAssertFalse(observation.isUsableRanking(for: "2026-11-25", now: now))
        }
    }
    func testTypedFailureNeverLooksLikeFreshRanking() throws {
        let raw = Data(#"{"status":"unavailable","error_code":"rate_limited"}"#.utf8)
        let value = try JSONDecoder().decode(ProviderObservation.self, from: raw)
        XCTAssertEqual(value.errorCode, .rateLimited)
        XCTAssertFalse(value.isUsableRanking(for: "2026-11-25", now: Date()))
        XCTAssertTrue(value.displayStatus(for: "2026-11-25", now: Date()).contains("限流"))
    }
    func testStandaloneProviderDecodesAndRejectsStaleObservation() throws {
        let raw = Data(#"{"status":"listed","requested_date":"2026-11-25","retrieved_at":"2026-11-25T12:00:00Z","rank":7,"download_display":"2 GB","upload_display":"1 GB","total_display":"3 GB","units_verified":false}"#.utf8)
        let value = try JSONDecoder().decode(ProviderObservation.self, from: raw)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:30Z"))
        XCTAssertTrue(value.isFresh(for: "2026-11-25", now: now))
        XCTAssertFalse(value.isFresh(for: "2026-11-25", now: now.addingTimeInterval(601)))
        XCTAssertTrue(value.displayStatus(for: "2026-11-25", now: now).contains("未驗證"))
    }
}
