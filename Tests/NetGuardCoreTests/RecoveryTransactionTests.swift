import XCTest
@testable import NetGuardCore

final class RecoveryTransactionTests: XCTestCase {
    let old = OwnedNetworkConfiguration(revision: 1, settings: ["owned": "old"])
    let new = OwnedNetworkConfiguration(revision: 2, settings: ["owned": "new"])
    let restored = OwnedNetworkConfiguration(revision: 3, settings: ["owned": "old"])
    func plan() -> RecoveryPlan {
        RecoveryPlan(transactionID: UUID(), expected: old, desired: new.settings)
    }

    func testAuthorizationAndOwnership() {
        var tx = RecoveryTransaction()
        XCTAssertEqual(tx.begin(plan(), observed: old, authorized: false), .finish(.rejected))
        let bad = RecoveryPlan(transactionID: UUID(), expected: old, desired: ["unowned": "new"])
        XCTAssertEqual(tx.begin(bad, observed: old, authorized: true), .finish(.rejected))
    }
    func testJournalBeforeWriteAndCommit() {
        var tx = RecoveryTransaction()
        let p = plan()
        guard case .persist(let prepared) = tx.begin(p, observed: old, authorized: true) else {
            return XCTFail("must journal before mutation")
        }
        XCTAssertEqual(prepared.phase, .prepared)
        XCTAssertEqual(tx.persisted(success: true), .compareAndSwap(expected: old, desired: new.settings))
        guard case .persist(let applied) = tx.mutationResult(new) else { return XCTFail() }
        XCTAssertEqual(applied.phase, .applied)
        XCTAssertEqual(tx.persisted(success: true), .verify(new))
        guard case .persist(let committed) = tx.verified(new) else { return XCTFail() }
        XCTAssertEqual(committed.phase, .committed)
        XCTAssertEqual(tx.persisted(success: true), .finish(.committed))
    }
    func testFailedInitialJournalNeverMutates() {
        var tx = RecoveryTransaction()
        _ = tx.begin(plan(), observed: old, authorized: true)
        XCTAssertEqual(tx.persisted(success: false), .finish(.rejected))
    }
    func testVerificationFailureRollsBackUsingExactRevision() {
        var tx = RecoveryTransaction()
        _ = tx.begin(plan(), observed: old, authorized: true)
        _ = tx.persisted(success: true)
        _ = tx.mutationResult(new)
        _ = tx.persisted(success: true)
        XCTAssertEqual(tx.verified(nil), .compareAndSwap(expected: new, desired: old.settings))
        XCTAssertEqual(tx.mutationResult(restored), .verify(restored))
        guard case .persist(let entry) = tx.verified(restored) else { return XCTFail() }
        XCTAssertEqual(entry.phase, .rolledBack)
        XCTAssertEqual(tx.persisted(success: true), .finish(.rolledBack))
    }
    func testUnknownMutationAndExternalConflictStop() {
        var tx = RecoveryTransaction()
        _ = tx.begin(plan(), observed: old, authorized: true)
        _ = tx.persisted(success: true)
        XCTAssertEqual(tx.mutationResult(nil), .finish(.safeMode))
        var entry = RecoveryJournalEntry(plan: plan())
        entry.phase = .applied
        entry.applied = new
        var recovery = RecoveryTransaction()
        let external = OwnedNetworkConfiguration(revision: 3, settings: new.settings)
        XCTAssertEqual(recovery.recover(entry, observed: external), .finish(.safeMode))
    }
    func testCrashPreparedAndApplied() {
        let p = plan()
        var entry = RecoveryJournalEntry(plan: p)
        var first = RecoveryTransaction()
        XCTAssertEqual(first.recover(entry, observed: new), .finish(.safeMode))
        entry.phase = .applied
        entry.applied = new
        var second = RecoveryTransaction()
        XCTAssertEqual(second.recover(entry, observed: new),
                       .compareAndSwap(expected: new, desired: old.settings))
    }
    func testCommitJournalFailureRollsBack() {
        var tx = RecoveryTransaction()
        _ = tx.begin(plan(), observed: old, authorized: true)
        _ = tx.persisted(success: true)
        _ = tx.mutationResult(new)
        _ = tx.persisted(success: true)
        _ = tx.verified(new)
        XCTAssertEqual(tx.persisted(success: false), .compareAndSwap(expected: new, desired: old.settings))
    }
}
