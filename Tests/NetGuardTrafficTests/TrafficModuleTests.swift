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

    func test64BitCountersCross4GiBWithoutResetAndGenerationChangeDiscardsInterval() {
        var engine = ScopedCounterAccumulator()
        func sample(_ bytes: UInt64, _ identity: String, _ generation: String?) -> ScopedInterfaceSample {
            .init(counters: .init(interfaceID: "en0", received: bytes, sent: bytes),
                  scope: .dorm, identity: identity, counterGeneration: generation)
        }
        let boundary: UInt64 = 1 << 32
        _ = engine.ingest([sample(boundary - 10, "a", "1")], day: "2026-11-26", uptime: 1)
        let crossed = engine.ingest([sample(boundary + 10, "a", "1")], day: "2026-11-26", uptime: 2)
        XCTAssertEqual(crossed["en0"]?.delta.received, 20)
        XCTAssertEqual(crossed["en0"]?.scope, .dorm)
        let changed = engine.ingest([sample(boundary + 50, "a", "2")], day: "2026-11-26", uptime: 3)
        XCTAssertEqual(changed["en0"]?.delta.quality, .unknown)
        let next = engine.ingest([sample(boundary + 60, "a", "2")], day: "2026-11-26", uptime: 4)
        XCTAssertEqual(next["en0"]?.delta.received, 10)
        XCTAssertEqual(next["en0"]?.scope, .dorm)
        XCTAssertEqual(engine.ingest([sample(boundary + 70, "a", nil)], day: "2026-11-26", uptime: 5)["en0"]?.delta.quality, .unknown)
    }

    func testMissingScopeIdentityRetainsOnlyUnattributedBytes() {
        var engine = ScopedCounterAccumulator()
        func sample(_ bytes: UInt64, _ identity: String) -> ScopedInterfaceSample {
            .init(counters: .init(interfaceID: "en0", received: bytes, sent: 0), scope: .dorm, identity: identity)
        }
        _ = engine.ingest([sample(10, "")], day: "d", uptime: 1)
        let delta = engine.ingest([sample(20, "")], day: "d", uptime: 2)
        XCTAssertEqual(delta["en0"]?.scope, .unknown)
        XCTAssertEqual(delta["en0"]?.delta.received, 10)
        XCTAssertEqual(InterfaceScopeProjection.scopes([sample(20, "")]), ["en0": .unknown])
        XCTAssertEqual(InterfaceScopeProjection.scopes([sample(20, "a\n")]), ["en0": .unknown])
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
    func testBackwardDayNeverRequestsRollover() {
        XCTAssertEqual(LocalDayTransition.evaluate(previous: "2026-11-26", observed: "2026-11-25"), .backward)
        XCTAssertEqual(LocalDayTransition.evaluate(previous: "2026-11-26", observed: "2026-11-26"), .unchanged)
        XCTAssertEqual(LocalDayTransition.evaluate(previous: "2026-11-26", observed: "2026-11-27"), .forward)
        XCTAssertEqual(LocalDayTransition.evaluate(previous: "", observed: "2026-11-27"), .forward)
    }
    func testCoverageDistinguishesMeasuredZeroAndUnknown() throws {
        var coverage = DailyScopeCoverage()
        coverage.observe(.init(scope: .dorm, delta: .init(received: 0, sent: 0, quality: .unknown)))
        XCTAssertFalse(coverage.observed(.dorm))
        coverage.observe(.init(scope: .dorm, delta: .init(received: 0, sent: 0, quality: .measured)))
        coverage.observe(.init(scope: .unknown, delta: .init(received: 10, sent: 0, quality: .measured)))
        XCTAssertTrue(coverage.observed(.dorm))
        XCTAssertFalse(coverage.observed(.unknown))
        XCTAssertEqual(DailyScopeCoverage.restore(coverage.persisted), coverage)
        XCTAssertNil(DailyScopeCoverage.restore(["dorm", "dorm"]))
        XCTAssertNil(DailyScopeCoverage.restore(["unknown"]))
    }
    func testScopeProjectionRejectsAmbiguousIdentity() {
        let counters = InterfaceCounters(interfaceID: "en0", received: 1, sent: 2)
        XCTAssertEqual(InterfaceScopeProjection.scopes([
            .init(counters: counters, scope: .dorm, identity: "a"),
            .init(counters: counters, scope: .external, identity: "b")
        ])["en0"], .unknown)
    }

    func testLocalScopeInferenceRequiresUnambiguousEvidence() {
        let cases: [([String], Bool, Bool, NetworkScope?, NetworkScope)] = [
            (["140.120.1.2"], false, false, nil, .unknown),
            (["140.120.1.2"], false, true, nil, .campusWifi),
            (["140.120.1.2", "172.20.10.3"], false, true, nil, .unknown),
            (["140.120.1.2", "192.0.2.3"], false, true, nil, .unknown),
            (["172.20.10.3"], false, true, nil, .external),
            (["140.120.1.2", "169.254.1.1"], false, true, nil, .campusWifi),
            (["140.120.999.2"], false, true, nil, .unknown),
            (["140.120.1.2"], false, false, .dorm, .dorm),
            (["169.254.1.1"], false, false, .dorm, .unknown),
            (["127.0.0.1"], false, false, .dorm, .unknown),
            ([], true, false, .dorm, .dorm),
            ([], true, true, nil, .unknown),
            ([], false, false, .external, .unknown),
            (["140.120.1.2", "bad"], false, true, .dorm, .unknown)
        ]
        for (ips, v6, wifi, explicit, expected) in cases {
            XCTAssertEqual(InterfaceScopeEvidence.resolve(ipv4: ips, hasUsableIPv6: v6,
                isWiFi: wifi, explicit: explicit), expected, "IPv4 fixture: \(ips)")
        }
    }


    func testManualScopeSelectionNeverFollowsChangedIdentityOrGeneration() throws {
        func sample(_ id: String = "en0", _ identity: String = "network-a",
                    _ generation: String? = "1", _ bytes: UInt64 = 0) -> ScopedInterfaceSample {
            .init(counters: .init(interfaceID: id, received: bytes, sent: bytes),
                  scope: .unknown, identity: identity, counterGeneration: generation)
        }
        let selected = try XCTUnwrap(ManualScopeSelection(scope: .dorm, sample: sample()))
        XCTAssertTrue(selected.matches(sample("en0", "network-a", "1", 500)))
        XCTAssertFalse(selected.matches(sample("en1")))
        XCTAssertFalse(selected.matches(sample("en0", "network-b")))
        XCTAssertFalse(selected.matches(sample("en0", "network-a", "2")))
        XCTAssertFalse(selected.matches(sample("en0", "network-a", nil)))
        XCTAssertNil(ManualScopeSelection(scope: .unknown, sample: sample()))
        XCTAssertNil(ManualScopeSelection(scope: .dorm, sample: sample("en0", "")))
        XCTAssertNil(ManualScopeSelection(scope: .dorm, sample: sample("en0", "network-a", nil)))
        XCTAssertNil(ManualScopeSelection(scope: .dorm, sample: sample("en0", "network-a", "\n")))
    }

}
