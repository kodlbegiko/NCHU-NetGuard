import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
    func testOversizedJournalRejectedWithoutOverwriting() throws {
        try withStore { store in
            let payload = Data(repeating: 0x20, count: 1_048_577)
            try payload.write(to: store.url)
            XCTAssertEqual(chmod(store.url.path, 0o600), 0)
            XCTAssertThrowsError(try store.load()) {
                XCTAssertEqual($0 as? JournalValidationError, .oversized)
            }
            XCTAssertThrowsError(try store.save(RecoveryJournalEntry(plan: plan()))) {
                XCTAssertEqual($0 as? JournalValidationError, .oversized)
            }
            XCTAssertEqual(try Data(contentsOf: store.url), payload)
        }
    }
    func testJournalSymlinkRejectedWithoutChangingTarget() throws {
        try withStore { store in
            let target = store.url.deletingLastPathComponent().appendingPathComponent("other.json")
            let payload = Data("preserve".utf8)
            try payload.write(to: target)
            try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(RecoveryJournalEntry(plan: plan())))
            XCTAssertEqual(try Data(contentsOf: target), payload)
        }
    }
    func testCompetingWriterCannotChangeJournal() throws {
        try withStore { store in
            let first = RecoveryJournalEntry(plan: plan())
            try store.save(first)
            let fd = open(store.url.path + ".lock", O_RDWR | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { return }
            defer { _ = flock(fd, LOCK_UN); _ = close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try store.save(first)) {
                XCTAssertEqual($0 as? JournalValidationError, .lockBusy)
            }
        }
    }
    func testAppliedEvidenceCannotBeRewritten() throws {
        try withStore { store in
            var entry = RecoveryJournalEntry(plan: plan())
            try store.save(entry)
            entry.phase = .applied
            entry.applied = .init(revision: 2, settings: entry.plan.desired)
            try store.save(entry)
            let original = entry
            entry.phase = .committed
            entry.applied = .init(revision: 3, settings: entry.plan.desired)
            XCTAssertThrowsError(try store.save(entry))
            XCTAssertEqual(try store.load(), original)
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
    func testNewRolledBackJournalRequiresVerifiedRestoration() throws {
        try withStore { store in
            var entry = RecoveryJournalEntry(plan: plan())
            try store.save(entry)
            entry.phase = .applied
            entry.applied = .init(revision: 2, settings: entry.plan.desired)
            try store.save(entry)
            entry.phase = .rolledBack
            XCTAssertThrowsError(try store.save(entry))
            XCTAssertEqual(try store.load()?.phase, .applied)
            entry.restored = .init(revision: 3, settings: entry.plan.expected.settings)
            try store.save(entry)
            XCTAssertEqual(try store.load(), entry)
            entry.restored = .init(revision: 4, settings: entry.plan.expected.settings)
            XCTAssertThrowsError(try store.save(entry))
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
    func testUnsafeJournalPermissionsAndParentAreRejected() throws {
        try withStore { store in
            let entry = RecoveryJournalEntry(plan: plan())
            try store.save(entry)
            let original = try Data(contentsOf: store.url)
            XCTAssertEqual(chmod(store.url.path, 0o644), 0)
            XCTAssertThrowsError(try store.load()) {
                XCTAssertEqual($0 as? JournalValidationError, .invalidPlan)
            }
            XCTAssertThrowsError(try store.save(entry))
            XCTAssertEqual(try Data(contentsOf: store.url), original)
            XCTAssertEqual(chmod(store.url.path, 0o600), 0)
            XCTAssertEqual(chmod(store.url.path + ".lock", 0o666), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(chmod(store.url.path + ".lock", 0o600), 0)
            let parent = store.url.deletingLastPathComponent()
            XCTAssertEqual(chmod(parent.path, 0o777), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(chmod(parent.path, 0o700), 0)
            XCTAssertEqual(try store.load(), entry)
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
