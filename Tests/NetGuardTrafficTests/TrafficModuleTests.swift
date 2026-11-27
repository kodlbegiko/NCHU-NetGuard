import Foundation
import XCTest
import NetGuardTraffic

final class TrafficModuleTests: XCTestCase {
    func testSyntheticSevenDayAccountingStressWithFaults() {
        // 604,800 one-second synthetic intervals. No socket, network probe,
        // machine clock change or user data. Oracle uses the scripted input,
        // not a second instance of the accumulator under test.
        var engine = ScopedCounterAccumulator()
        var received: UInt64 = 0, sent: UInt64 = 0
        let rxStep: UInt64 = 65_536, txStep: UInt64 = 8_192
        for dayIndex in 0..<7 {
            let day = String(format: "2026-11-%02d", 20 + dayIndex)
            var ledger = DailyTrafficLedger()
            var expectedRX: UInt64 = 0, expectedTX: UInt64 = 0
            var expectedUnknownRX: UInt64 = 0
            for tick in 0..<86_400 {
                if tick == 43_200 { received = 0; sent = 0 }
                else { received += rxStep; sent += txStep }
                let scope: NetworkScope = tick >= 3_000 ? .campusWifi : .dorm
                let physical = ScopedInterfaceSample(
                    counters: .init(interfaceID: "en0", received: received, sent: sent),
                    scope: scope, identity: scope.rawValue,
                    counterGeneration: tick < 43_200 ? "1" : "2")
                let zero = ScopedInterfaceSample(
                    counters: .init(interfaceID: "en1", received: 0, sent: 0),
                    scope: .external, identity: "fixture", counterGeneration: "3")
                var inputs = [zero]
                if tick != 1_000 { inputs.append(physical) }
                if tick == 2_000 { inputs.append(physical) }
                let result = engine.ingest(inputs, day: day,
                    uptime: Double(dayIndex * 86_400 + tick + 1))
                let valid = ![0, 1_000, 1_001, 2_000, 2_001, 43_200].contains(tick)
                if valid {
                    guard let actual = result["en0"],
                          actual.delta == .init(received: rxStep, sent: txStep, quality: .measured),
                          actual.scope == (tick == 3_000 ? .unknown : scope)
                    else { XCTFail("unexpected synthetic physical delta"); return }
                    expectedRX += rxStep; expectedTX += txStep
                    if tick == 3_000 { expectedUnknownRX += rxStep }
                } else if result["en0"]?.delta.quality != .unknown {
                    XCTFail("invalid interval accepted"); return
                }
                if tick > 0 && result["en1"] != .init(scope: .external,
                        delta: .init(received: 0, sent: 0, quality: .measured)) {
                    XCTFail("measured zero lost"); return
                }
                for value in result.values where value.delta.quality == .measured {
                    if !ledger.add(scope: value.scope, received: value.delta.received, sent: value.delta.sent) {
                        XCTFail("valid synthetic ledger rejected"); return
                    }
                }
            }
            XCTAssertEqual(ledger.aggregate, .init(received: expectedRX, sent: expectedTX))
            XCTAssertEqual(ledger.totals(for: .unknown).received, expectedUnknownRX)
            XCTAssertGreaterThan(ledger.aggregate.received, UInt64(1) << 32)
        }
    }

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


    func testMalformedCounterIdentityDropsBaselineAndNeverProjectsScope() {
        let day = "2026-11-27"
        func sample(_ bytes: UInt64, _ generation: String?, id: String = "en0") -> ScopedInterfaceSample {
            .init(counters: .init(interfaceID: id, received: bytes, sent: bytes),
                  scope: .dorm, identity: "network", counterGeneration: generation)
        }
        for generation in ["", "\n", "a\u{0000}", String(repeating: "x", count: 129)] {
            var engine = ScopedCounterAccumulator()
            _ = engine.ingest([sample(10, "1")], day: day, uptime: 1)
            for tick in [2, 3] {
                let bad = sample(UInt64(tick * 10), generation)
                let delta = engine.ingest([bad], day: day, uptime: Double(tick))["en0"]
                XCTAssertEqual(delta, .init(scope: .unknown, delta: .init(received: 0, sent: 0, quality: .unknown)))
                XCTAssertEqual(InterfaceScopeProjection.scopes([bad])["en0"], .unknown)
            }
            XCTAssertEqual(engine.ingest([sample(40, "1")], day: day, uptime: 4)["en0"]?.delta.quality, .unknown)
            XCTAssertEqual(engine.ingest([sample(50, "1")], day: day, uptime: 5)["en0"]?.delta.received, 10)
        }
        for id in ["", "en0\n", String(repeating: "x", count: 129)] {
            let bad = sample(1, "1", id: id)
            XCTAssertEqual(InterfaceScopeProjection.scopes([bad])[id], .unknown)
            XCTAssertNil(ManualScopeSelection(scope: .dorm, sample: bad))
        }
    }

    func testDuplicateDisconnectGapAndMidnightRequireNewBaseline() {
        var engine = ScopedCounterAccumulator()
        func sample(_ bytes: UInt64, _ generation: String = "1") -> ScopedInterfaceSample {
            .init(counters: .init(interfaceID: "en0", received: bytes, sent: bytes),
                  scope: .dorm, identity: "network", counterGeneration: generation)
        }
        let day = "2026-11-27", tomorrow = "2026-11-28"
        _ = engine.ingest([sample(10)], day: day, uptime: 1)
        XCTAssertEqual(engine.ingest([sample(20), sample(30, "\n")], day: day, uptime: 2)["en0"]?.delta.quality, .unknown)
        XCTAssertEqual(engine.ingest([sample(40)], day: day, uptime: 3)["en0"]?.delta.quality, .unknown)
        XCTAssertEqual(engine.ingest([], day: day, uptime: 4)["en0"]?.delta.quality, .unknown)
        XCTAssertEqual(engine.ingest([sample(50)], day: day, uptime: 5)["en0"]?.delta.quality, .unknown)
        XCTAssertEqual(engine.ingest([sample(60)], day: day, uptime: 11)["en0"]?.delta.quality, .unknown)
        XCTAssertEqual(engine.ingest([sample(70)], day: tomorrow, uptime: 12)["en0"]?.delta.quality, .unknown)
        XCTAssertEqual(engine.ingest([sample(80)], day: tomorrow, uptime: 13)["en0"]?.delta.received, 10)
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
