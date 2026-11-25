import XCTest
@testable import NetGuardCore

final class RecoveryJournalStoreTests: XCTestCase {
    func withStore(_ body: (RecoveryJournalStore) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(RecoveryJournalStore(url: dir.appendingPathComponent("journal.json")))
    }
    func plan() -> RecoveryPlan {
        RecoveryPlan(transactionID: UUID(),
            expected: OwnedNetworkConfiguration(revision: 1, settings: ["owned":"before"]),
            desired: ["owned":"after"])
    }
    func testRoundTripAndMonotonicPhase() throws {
        try withStore { store in
            var entry = RecoveryJournalEntry(plan: plan())
            XCTAssertNil(try store.load())
            try store.save(entry)
            XCTAssertEqual(try store.load(), entry)
            entry.phase = .applied
            entry.applied = OwnedNetworkConfiguration(revision: 2, settings: entry.plan.desired)
            try store.save(entry)
            XCTAssertEqual(try store.load(), entry)
            XCTAssertThrowsError(try store.save(RecoveryJournalEntry(plan: entry.plan)))
            entry.phase = .committed
            try store.save(entry)
            XCTAssertEqual(try store.load()?.phase, .committed)
            entry.phase = .rolledBack
            XCTAssertThrowsError(try store.save(entry))
        }
    }
    func testMalformedJournalIsNotOverwritten() throws {
        try withStore { store in
            let bad = Data("invalid".utf8)
            try bad.write(to: store.url)
            XCTAssertThrowsError(try store.save(RecoveryJournalEntry(plan: plan())))
            XCTAssertEqual(try Data(contentsOf: store.url), bad)
        }
    }
    func testOtherTransactionCannotReplaceJournal() throws {
        try withStore { store in
            let first = RecoveryJournalEntry(plan: plan())
            try store.save(first)
            XCTAssertThrowsError(try store.save(RecoveryJournalEntry(plan: plan())))
            XCTAssertEqual(try store.load(), first)
        }
    }
    func testInvalidPhaseRejected() throws {
        try withStore { store in
            var entry = RecoveryJournalEntry(plan: plan())
            entry.phase = .applied
            XCTAssertThrowsError(try store.save(entry))
            XCTAssertNil(try store.load())
        }
    }
    func testSimulationRefusesConflictingWrite() {
        let p = plan()
        var adapter = SimulatedNetworkAdapter(configuration: p.expected)
        let applied = adapter.compareAndSwap(expected: p.expected, desired: p.desired)
        XCTAssertNotNil(applied)
        adapter.externalEdit(settings: ["owned":"external"])
        XCTAssertNil(adapter.compareAndSwap(expected: applied!, desired: p.expected.settings))
        XCTAssertEqual(adapter.configuration.settings, ["owned":"external"])
        XCTAssertEqual(adapter.writes, 1)
    }
}
