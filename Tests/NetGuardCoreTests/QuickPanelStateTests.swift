import XCTest
import NetGuardCore

final class QuickPanelStateTests: XCTestCase {
    private func state(_ scope: NetworkScope, known: Bool) -> QuickPanelState {
        QuickPanelState(networkName: "fixture", connectionKnown: known, scope: scope,
            received: 20, sent: 50, receiveLimit: 100, sendLimit: 40, speedText: "sample",
            diagnostic: "fixture", forecast: "forecast", provider: "fixture",
            focusEnabled: false, alertsEnabled: true)
    }
    func testUnknownNeverShowsRemainingQuota() {
        XCTAssertNil(state(.unknown, known: true).download)
        XCTAssertNil(state(.external, known: true).upload)
        XCTAssertNil(state(.dorm, known: false).download)
        XCTAssertEqual(state(.dorm, known: false).speedText, "未量測")
    }
    func testBudgetClampsOveruseButPreservesUsed() {
        let s = state(.dorm, known: true)
        XCTAssertEqual(s.download?.remaining, 80)
        XCTAssertEqual(s.upload?.remaining, 0)
        XCTAssertEqual(s.upload?.used, 50)
        XCTAssertEqual(s.upload?.fraction, 1)
    }
    func testInvalidInputsRejected() {
        XCTAssertNil(QuickPanelBudget(used: .nan, limit: 100))
        XCTAssertNil(QuickPanelBudget(used: -1, limit: 100))
        XCTAssertNil(QuickPanelBudget(used: 0, limit: 0))
        XCTAssertNil(QuickPanelBudget(used: 0.5, limit: 100))
    }
}
