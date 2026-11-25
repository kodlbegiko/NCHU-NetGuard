import Foundation
import XCTest
import NetGuardProvider

final class ProviderModuleTests: XCTestCase {
    func testStandaloneProviderDecodesAndRejectsStaleObservation() throws {
        let raw = Data(#"{"status":"listed","requested_date":"2026-11-25","retrieved_at":"2026-11-25T12:00:00Z","rank":7,"download_display":"2 GB","upload_display":"1 GB","total_display":"3 GB","units_verified":false}"#.utf8)
        let value = try JSONDecoder().decode(ProviderObservation.self, from: raw)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:30Z"))
        XCTAssertTrue(value.isFresh(for: "2026-11-25", now: now))
        XCTAssertFalse(value.isFresh(for: "2026-11-25", now: now.addingTimeInterval(601)))
        XCTAssertTrue(value.displayStatus(for: "2026-11-25", now: now).contains("未驗證"))
    }
}
