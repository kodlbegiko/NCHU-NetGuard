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
    func testFlowPartitionReconcilesOnlyComparableDirectionalTotals() throws {
        let rows = [
            RouteClassifiedDelta(identity: "a", route: .localNetwork, bytes: .init(received: 10, sent: 20)),
            RouteClassifiedDelta(identity: "b", route: .internet, bytes: .init(received: 30, sent: 40))
        ]
        let partial = try XCTUnwrap(FlowPartitionProjection.summarize(rows, boundary: .socketPayload))
        XCTAssertFalse(partial.reconciled)
        let complete = try XCTUnwrap(FlowPartitionProjection.summarize(rows, boundary: .socketPayload,
            comparableTotal: .init(received: 40, sent: 60)))
        XCTAssertTrue(complete.reconciled)
        let gap = try XCTUnwrap(FlowPartitionProjection.summarize(rows, boundary: .socketPayload,
            comparableTotal: .init(received: 50, sent: 60)))
        XCTAssertEqual(gap.unclassified, .init(received: 10, sent: 0))
        XCTAssertFalse(gap.reconciled)
        XCTAssertNil(FlowPartitionProjection.summarize(rows, boundary: .socketPayload,
            comparableTotal: .init(received: 39, sent: 61)))
        XCTAssertNil(FlowPartitionProjection.summarize(rows + [rows[0]], boundary: .physicalWire))
    }
    func testFlowPartitionUnknownAndOverflowFailClosed() throws {
        let row = RouteClassifiedDelta(identity: "x", route: .unknown, bytes: .init(received: 0, sent: 0))
        let result = try XCTUnwrap(FlowPartitionProjection.summarize([row], boundary: .physicalWire,
            comparableTotal: .init()))
        XCTAssertFalse(result.reconciled)
        XCTAssertNil(FlowPartitionProjection.summarize([
            .init(identity: "x", route: .internet, bytes: .init(received: UInt64.max, sent: 1))
        ], boundary: .socketPayload))
    }
    func testScopeProjectionRejectsAmbiguousIdentity() {
        let counters = InterfaceCounters(interfaceID: "en0", received: 1, sent: 2)
        XCTAssertEqual(InterfaceScopeProjection.scopes([
            .init(counters: counters, scope: .dorm, identity: "a"),
            .init(counters: counters, scope: .external, identity: "b")
        ])["en0"], .unknown)
    }
}
