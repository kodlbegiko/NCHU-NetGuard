import Foundation
import XCTest
import NetGuardTraffic

final class TrafficModuleTests: XCTestCase {
    func testStandaloneScopedAccounting() {
        var accumulator = ScopedCounterAccumulator()
        func sample(_ id: String, _ value: UInt64, _ scope: NetworkScope) -> ScopedInterfaceSample {
            .init(counters: .init(interfaceID: id, received: value, sent: value), scope: scope, identity: id)
        }
        _ = accumulator.ingest([sample("en0", 10, .dorm), sample("en1", 20, .external)], day: "2026-11-25", uptime: 1)
        let result = accumulator.ingest([sample("en0", 15, .dorm)], day: "2026-11-25", uptime: 2)
        XCTAssertEqual(result["en0"], ScopedTrafficDelta(scope: .dorm, delta: .init(received: 5, sent: 5, quality: .measured)))
        XCTAssertEqual(result["en1"]?.delta.quality, .unknown)
    }

    func testDailyLedgerUsesExactIntegerTotalsAndRejectsOverflowAtomically() {
        var ledger = DailyTrafficLedger()
        XCTAssertTrue(ledger.add(scope: .dorm, received: 10, sent: 5))
        XCTAssertTrue(ledger.add(scope: .external, received: 20, sent: 2))
        XCTAssertTrue(ledger.add(scope: .unknown, received: 1, sent: 0))
        XCTAssertEqual(ledger.aggregate, .init(received: 31, sent: 7))
        XCTAssertEqual(ledger.totals(for: .dorm), .init(received: 10, sent: 5))
        let prior = ledger
        XCTAssertFalse(ledger.add(scope: .campusWifi, received: UInt64.max, sent: 1))
        XCTAssertEqual(ledger, prior)
        XCTAssertFalse(ledger.add(scope: .dorm, received: DailyTrafficLedger.maximumTotal, sent: 0))
        XCTAssertEqual(ledger, prior)
    }
    func testExactCeilingAndNextByteRejected() {
        var ledger = DailyTrafficLedger()
        XCTAssertTrue(ledger.add(scope: .external, received: DailyTrafficLedger.maximumTotal - 1, sent: 1))
        XCTAssertFalse(ledger.add(scope: .unknown, received: 1, sent: 0))
        XCTAssertEqual(ledger.aggregate.received, DailyTrafficLedger.maximumTotal - 1)
    }
    func testScopeProjectionRejectsAmbiguousIdentity() {
        let counters = InterfaceCounters(interfaceID: "en0", received: 1, sent: 2)
        XCTAssertEqual(InterfaceScopeProjection.scopes([
            .init(counters: counters, scope: .dorm, identity: "a"),
            .init(counters: counters, scope: .external, identity: "b")
        ])["en0"], .unknown)
    }
}
