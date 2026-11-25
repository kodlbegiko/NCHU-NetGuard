import XCTest
@testable import NetGuardCore

final class ProviderObservationTests: XCTestCase {
    func testFreshnessAndUnverifiedUnits() throws {
        let json = #"{"status":"listed","requested_date":"2026-11-25","retrieved_at":"2026-11-25T12:00:00.123456+00:00","rank":5,"download_display":"1.5 GB","upload_display":"30 MB","total_display":"1.53 GB","units_verified":false}"#
        let obs = try JSONDecoder().decode(ProviderObservation.self, from: Data(json.utf8))
        let now = ISO8601DateFormatter().date(from: "2026-11-25T12:01:00Z")!
        XCTAssertTrue(obs.isFresh(for: "2026-11-25", now: now))
        XCTAssertTrue(obs.displayStatus(for: "2026-11-25", now: now).contains("單位與更新時間未驗證"))
        XCTAssertFalse(obs.isFresh(for: "2026-11-26", now: now))
        XCTAssertFalse(obs.isFresh(for: "2026-11-25", now: now.addingTimeInterval(601)))
    }
    func testUnavailableNeverMeansSafe() throws {
        let obs = try JSONDecoder().decode(ProviderObservation.self, from: Data(#"{"status":"unavailable"}"#.utf8))
        XCTAssertTrue(obs.displayStatus(for: "2026-11-25", now: Date()).contains("未知"))
    }
}
