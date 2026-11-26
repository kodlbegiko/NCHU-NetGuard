import XCTest
import NetGuardCore

final class QuickPanelStateTests: XCTestCase {
    private func state(_ scope: NetworkScope, known: Bool) -> QuickPanelState {
        QuickPanelState(networkName: "fixture", connectionKnown: known, scope: scope,
            received: 20, sent: 50, receiveLimit: 100, sendLimit: 40, speedText: "sample",
            diagnostic: "fixture", forecast: "forecast", provider: "fixture",
            focusEnabled: false, alertsEnabled: true)
    }
    func testScopeSelectionNeverClaimsOfflineOrUnobservedQuota() {
        func selection(known: Bool) -> QuickPanelState {
            .init(networkName: "fixture", connectionKnown: known, scope: .unknown,
                  received: 0, sent: 0, receiveLimit: 100, sendLimit: 100,
                  speedText: "sample", diagnostic: "fixture", forecast: "fixture",
                  provider: "fixture", focusEnabled: false, alertsEnabled: true,
                  selectedScope: .dorm, canSelectScope: true)
        }
        XCTAssertTrue(selection(known: true).canSelectScope)
        XCTAssertEqual(selection(known: true).selectedScope, .dorm)
        XCTAssertNil(selection(known: true).download)
        XCTAssertFalse(selection(known: false).canSelectScope)
        XCTAssertEqual(selection(known: false).selectedScope, .unknown)
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

    func testUnknownConnectionSuppressesLiveTrend() {
        var window = ThroughputWindow()
        window.ingest(identity: "fixture", uptime: 1, download: 2, upload: 3)
        let points = window.recent(at: 1)
        XCTAssertEqual(points.count, 1)
        let result = QuickPanelState(networkName: "fixture", connectionKnown: false, scope: .unknown,
            received: 0, sent: 0, receiveLimit: 1, sendLimit: 1, speedText: "fixture",
            diagnostic: "fixture", forecast: "fixture", provider: "fixture",
            focusEnabled: false, alertsEnabled: true, throughput: points)
        XCTAssertTrue(result.throughput.isEmpty)
    }

}
