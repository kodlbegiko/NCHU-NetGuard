import XCTest
import NetGuardCore

final class AutomationSnapshotTests: XCTestCase {
    func testLedgerRestoresAndAllowsEscalationOnly() throws {
        var ledger = QuotaAlertLedger()
        XCTAssertTrue(ledger.shouldNotify(day: "2026-11-25", scope: .dorm, tier: .warning, enabled: true))
        var restored = QuotaAlertLedger()
        try restored.restore(day: "2026-11-25", tiers: ledger.persistedTiers(day: "2026-11-25"))
        XCTAssertFalse(restored.shouldNotify(day: "2026-11-25", scope: .dorm, tier: .warning, enabled: true))
        XCTAssertTrue(restored.shouldNotify(day: "2026-11-25", scope: .dorm, tier: .high, enabled: true))
        XCTAssertTrue(restored.shouldNotify(day: "2026-11-26", scope: .dorm, tier: .warning, enabled: true))
    }
    func testInvalidLedgerDoesNotReplaceValidState() throws {
        var ledger = QuotaAlertLedger()
        try ledger.restore(day: "2026-11-25", tiers: ["dorm": 2])
        XCTAssertThrowsError(try ledger.restore(day: "2026-11-25", tiers: ["external": 3]))
        XCTAssertThrowsError(try ledger.restore(day: "2026-11-25", tiers: ["dorm": 99]))
        XCTAssertEqual(ledger.recordedTier(day: "2026-11-25", scope: .dorm), .high)
        XCTAssertEqual(ledger.recordedTier(day: "2026-11-26", scope: .dorm), .normal)
    }
    func testSleepingAndUnknownDoNotAssertQuota() {
        let ledger = QuotaAlertLedger()
        let assessment = LocalQuotaPolicy.assess(received: 95, sent: 0, receiveLimit: 100, sendLimit: 100, totalLimit: 200)
        let snapshot = AutomationSnapshot(alertsEnabled: true, focusEnabled: true, sleeping: true,
            assessment: assessment, ledger: ledger, day: "2026-11-25", ledgerStatus: "fixture")
        XCTAssertNil(snapshot.quotaTier)
        XCTAssertEqual(AutomationSnapshot.tierLabel(snapshot.quotaTier), "配額未確認")
    }
}
