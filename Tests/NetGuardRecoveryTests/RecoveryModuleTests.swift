import Foundation
import XCTest
import NetGuardRecovery

final class RecoveryModuleTests: XCTestCase {
    func testStandaloneRecoveryWithSimulatedAdapter() throws {
        let before = OwnedNetworkConfiguration(revision: 1, settings: ["fixture": "old"])
        let plan = RecoveryPlan(transactionID: UUID(), expected: before, desired: ["fixture": "new"])
        var adapter = SimulatedNetworkAdapter(configuration: before)
        var transaction = RecoveryTransaction()
        guard case .persist(let prepared) = transaction.begin(plan, observed: before, authorized: true)
        else { return XCTFail("expected prepared journal") }
        try prepared.validate()
        guard case .compareAndSwap(let expected, let desired) = transaction.persisted(success: true)
        else { return XCTFail("expected simulated effect") }
        let changed = adapter.compareAndSwap(expected: expected, desired: desired)
        guard case .persist(let applied) = transaction.mutationResult(changed)
        else { return XCTFail("expected applied journal") }
        try applied.validate()
        guard case .verify(let observed) = transaction.persisted(success: true)
        else { return XCTFail("expected verification") }
        guard case .persist(let committed) = transaction.verified(observed)
        else { return XCTFail("expected committed journal") }
        XCTAssertEqual(committed.phase, .committed)
        XCTAssertEqual(transaction.persisted(success: true), .finish(.committed))
        XCTAssertEqual(adapter.writes, 1)
    }
}
