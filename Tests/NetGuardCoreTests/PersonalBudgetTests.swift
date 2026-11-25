import Foundation
import XCTest
import NetGuardCore

final class PersonalBudgetTests: XCTestCase {
    func testPersonalBudgetUsesDecimalGBAndClampsRemaining() throws {
        let budget = try PersonalDailyBudget(scope: .external, decimalGigabytes: 5)
        XCTAssertEqual(budget.limitBytes, 5_000_000_000)
        XCTAssertEqual(budget.evaluate(received: 4_000_000_000, sent: 2_000_000_000, observed: true)?.remaining, 0)
        XCTAssertEqual(budget.evaluate(received: 1_000_000_000, sent: 1_000_000_000, observed: true)?.remaining, 3_000_000_000)
        XCTAssertNil(budget.evaluate(received: 0, sent: 0, observed: false))
        XCTAssertNil(budget.evaluate(received: UInt64.max, sent: 1, observed: true))
    }

    func testRejectInvalidScopeAndCorruptPreference() throws {
        XCTAssertThrowsError(try PersonalDailyBudget(scope: .unknown, decimalGigabytes: 5))
        XCTAssertThrowsError(try PersonalDailyBudget(scope: .dorm, decimalGigabytes: 0))
        XCTAssertThrowsError(try PersonalDailyBudget(scope: .external, decimalGigabytes: 10001))
        let budget = try PersonalDailyBudget(scope: .campusWifi, decimalGigabytes: 10)
        XCTAssertEqual(try PersonalDailyBudget.decode(JSONEncoder().encode(budget)), budget)
        XCTAssertThrowsError(try PersonalDailyBudget.decode(Data(#"{"scope":"external","limitBytes":2}"#.utf8)))
    }

    func testSpeedUnitsAndUnavailableValues() {
        XCTAssertEqual(RateDisplayUnit.binaryBytes.format(1_048_576), "1.0 MiB/s")
        XCTAssertEqual(RateDisplayUnit.decimalBits.format(125_000), "1.0 Mbps")
        XCTAssertEqual(RateDisplayUnit.decimalBits.format(125), "1 kbps")
        XCTAssertEqual(RateDisplayUnit.binaryBytes.format(-1), "未量測")
        XCTAssertEqual(RateDisplayUnit.decimalBits.format(.infinity), "未量測")
    }
}
