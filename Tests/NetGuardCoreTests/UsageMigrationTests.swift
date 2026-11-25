import XCTest
@testable import NetGuardCore

final class UsageMigrationTests: XCTestCase {
    func decode(_ s: String) throws -> DailyUsageState { try UsageMigration.decode(Data(s.utf8)) }

    func testLegacyFallbackAndNoDoubleCount() throws {
        let old = try decode(#"{"date":"2026-11-25","today_in":100,"today_out":20,"last_raw_in":999,"is_split_routing_enabled":true}"#)
        XCTAssertEqual(old.dormIn, 100)
        XCTAssertEqual(old.dormOut, 20)
        let scoped = try decode(#"{"date":"2026-11-25","today_in":999,"dorm_in":100,"wifi_in":30,"unattributed_in":5}"#)
        XCTAssertEqual(scoped.dormIn, 100)
        XCTAssertEqual(scoped.wifiIn, 30)
        XCTAssertEqual(scoped.unattributedIn, 5)
    }

    func testRejectsMalformedValues() {
        for fixture in [
            #"{"date":"2026-02-30"}"#,
            #"{"date":"2026-11-25","dorm_in":-1}"#,
            #"{"date":"2026-11-25","dorm_in":true}"#,
            #"{"date":"2026-11-25","dorm_in":1.5}"#,
            #"{"date":"2026-11-25","dorm_in":"1"}"#,
            #"{"date":"2026-11-25","dorm_in":9007199254740992}"#,
            #"{"date":"2026-11-25","schema_version":2}"#,
            #"{"date":"2026-11-25","schema_version":true}"#
        ] {
            XCTAssertThrowsError(try decode(fixture), fixture)
        }
    }

    func testCurrentVersionPreservesCounts() throws {
        let s = try decode(#"{"schema_version":1,"date":"2026-11-25","dorm_in":10,"dorm_out":5,"ext_in":40,"sample_gap_count":2}"#)
        XCTAssertEqual(s.schemaVersion, 1)
        XCTAssertEqual(s.externalIn, 40)
        XCTAssertEqual(s.sampleGapCount, 2)
    }
}
