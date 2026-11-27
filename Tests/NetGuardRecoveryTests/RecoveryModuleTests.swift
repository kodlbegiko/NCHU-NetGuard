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

    func testJournalBackedFaultInjectionMatrix() throws {
        let before = OwnedNetworkConfiguration(revision: 1, settings: ["fixture": "old"])
        let cases: [(Set<RecoverySimulationFault>, RecoveryOutcome, Int)] = [
            ([], .committed, 1),
            ([.preparedNotWritten], .rejected, 0),
            ([.preparedUnknown], .rejected, 0),
            ([.externalBeforeApply], .safeMode, 0),
            ([.applyUnknown], .safeMode, 1),
            ([.appliedNotWritten], .rolledBack, 2),
            ([.appliedUnknown], .safeMode, 1),
            ([.verificationUnavailable], .rolledBack, 2),
            ([.externalBeforeVerify], .safeMode, 1),
            ([.committedNotWritten], .rolledBack, 2),
            ([.committedUnknown], .safeMode, 1),
            ([.verificationUnavailable, .rollbackUnknown], .safeMode, 2),
            ([.verificationUnavailable, .rollbackVerificationUnavailable], .safeMode, 2),
            ([.verificationUnavailable, .rolledBackNotWritten], .safeMode, 2),
            ([.verificationUnavailable, .rolledBackUnknown], .safeMode, 2)
        ]
        for (faults, outcome, writes) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = RecoveryJournalStore(url: directory.appendingPathComponent("journal.json"))
            let plan = RecoveryPlan(transactionID: UUID(), expected: before, desired: ["fixture":"new"])
            let result = RecoverySimulator.execute(plan: plan, observed: before, authorized: true,
                                                   store: store, faults: faults)
            XCTAssertEqual(result.outcome, outcome, "\(faults)")
            XCTAssertEqual(result.simulatedWrites, writes, "\(faults)")
            XCTAssertEqual(result.events.last, .finish(outcome))
            if let mutation = result.events.firstIndex(where: {
                if case .mutation = $0 { return true }; return false
            }) {
                XCTAssertTrue(result.events[..<mutation].contains(.persistence(.prepared, .persisted)))
            }
            if outcome == .rolledBack {
                XCTAssertEqual(result.configuration.settings, before.settings)
                XCTAssertEqual(try store.load()?.restored, result.configuration)
            }
        }
    }

    func testPreparedJournalCannotAuthorizeNewExecutionByReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryJournalStore(url: directory.appendingPathComponent("journal.json"))
        let before = OwnedNetworkConfiguration(revision: 1, settings: ["fixture":"old"])
        let plan = RecoveryPlan(transactionID: UUID(), expected: before, desired: ["fixture":"new"])
        let initial = RecoverySimulator.execute(plan: plan, observed: before, authorized: true,
                                               store: store, faults: [.preparedUnknown])
        XCTAssertEqual(initial.outcome, .rejected)
        XCTAssertEqual(initial.simulatedWrites, 0)
        let prepared = try XCTUnwrap(store.load())
        XCTAssertEqual(prepared.phase, .prepared)
        let replay = RecoverySimulator.execute(plan: plan, observed: before, authorized: true, store: store)
        XCTAssertEqual(replay.outcome, .rejected)
        XCTAssertEqual(replay.simulatedWrites, 0)
        XCTAssertEqual(try store.load(), prepared)
    }

    func testRestartNeverInfersUnknownApplyOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryJournalStore(url: directory.appendingPathComponent("journal.json"))
        let before = OwnedNetworkConfiguration(revision: 1, settings: ["fixture":"old"])
        let plan = RecoveryPlan(transactionID: UUID(), expected: before, desired: ["fixture":"new"])
        let interrupted = RecoverySimulator.execute(plan: plan, observed: before, authorized: true,
                                                        store: store, faults: [.applyUnknown])
        XCTAssertEqual(interrupted.outcome, .safeMode)
        let recovery = RecoverySimulator.restart(observed: interrupted.configuration, store: store)
        XCTAssertEqual(recovery.outcome, .safeMode)
        XCTAssertEqual(recovery.simulatedWrites, 0)
    }

    func testRestartFromPersistedAppliedEvidenceRestores() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryJournalStore(url: directory.appendingPathComponent("journal.json"))
        let before = OwnedNetworkConfiguration(revision: 1, settings: ["fixture":"old"])
        let plan = RecoveryPlan(transactionID: UUID(), expected: before, desired: ["fixture":"new"])
        let interrupted = RecoverySimulator.execute(plan: plan, observed: before, authorized: true,
                                                        store: store, faults: [.appliedUnknown])
        XCTAssertEqual(interrupted.outcome, .safeMode)
        let recovery = RecoverySimulator.restart(observed: interrupted.configuration, store: store)
        XCTAssertEqual(recovery.outcome, .rolledBack)
        XCTAssertEqual(recovery.simulatedWrites, 1)
        XCTAssertEqual(recovery.configuration.settings, before.settings)
        XCTAssertEqual(try store.load()?.restored, recovery.configuration)
    }
}
