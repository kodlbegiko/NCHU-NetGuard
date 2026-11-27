import XCTest
import NetGuardTraffic

final class ConnectionSessionMeterTests: XCTestCase {
    private func sample(_ identity: String = "a", scope: NetworkScope = .external,
                        generation: String? = nil) -> ScopedInterfaceSample {
        .init(counters: .init(interfaceID: "en0", received: 100, sent: 50), scope: scope,
              identity: identity, counterGeneration: generation)
    }
    private func delta(_ scope: NetworkScope = .external, quality: SampleQuality = .measured, received: UInt64 = 10, sent: UInt64 = 5) -> [String: ScopedTrafficDelta] {
        ["en0": .init(scope: scope, delta: .init(received: received, sent: sent, quality: quality))]
    }
    func testDropsInitialIntervalAndCountsDirections() throws {
        var meter = ConnectionSessionMeter()
        XCTAssertTrue(meter.begin(label: "Hotspot", gigabytes: 2, sample: sample()))
        meter.ingest(samples: [sample()], deltas: delta(), currentInterface: "en0", connectionKnown: true)
        XCTAssertEqual(meter.reading()?.intervals, 0)
        meter.ingest(samples: [sample()], deltas: delta(), currentInterface: "en0", connectionKnown: true)
        let result = try XCTUnwrap(meter.reading())
        XCTAssertEqual(result.received, 10)
        XCTAssertEqual(result.sent, 5)
        XCTAssertEqual(result.remaining, 1_999_999_985)
        XCTAssertEqual(result.intervals, 1)
    }
    func testIdentityChangeAndMissingSampleStopWithoutResuming() {
        var meter = ConnectionSessionMeter()
        XCTAssertTrue(meter.begin(label: "A", gigabytes: 1, sample: sample()))
        meter.ingest(samples: [sample("b")], deltas: delta(), currentInterface: "en0", connectionKnown: true)
        XCTAssertEqual(meter.reading()?.stopped, true)
        meter.ingest(samples: [sample()], deltas: delta(), currentInterface: "en0", connectionKnown: true)
        XCTAssertEqual(meter.reading()?.total, 0)
        XCTAssertTrue(meter.begin(label: "B", gigabytes: 1, sample: sample()))
        meter.ingest(samples: [], deltas: [:], currentInterface: "en0", connectionKnown: true)
        XCTAssertEqual(meter.reading()?.stopped, true)
    }
    func testScopeChangeAndDuplicateStop() {
        var meter = ConnectionSessionMeter()
        XCTAssertTrue(meter.begin(label: "A", gigabytes: 1, sample: sample()))
        meter.ingest(samples: [sample(scope: .unknown)], deltas: delta(.unknown), currentInterface: "en0", connectionKnown: true)
        XCTAssertEqual(meter.reading()?.stopped, true)
        XCTAssertTrue(meter.begin(label: "A", gigabytes: 1, sample: sample()))
        meter.ingest(samples: [sample(), sample()], deltas: delta(), currentInterface: "en0", connectionKnown: true)
        XCTAssertEqual(meter.reading()?.stopped, true)
    }
    func testSameInterfaceAndAddressButDifferentGenerationStopsSession() {
        var meter = ConnectionSessionMeter()
        XCTAssertFalse(meter.begin(label: "A", gigabytes: 1, sample: sample(generation: "\n")))
        XCTAssertTrue(meter.begin(label: "A", gigabytes: 1, sample: sample(generation: "1")))
        meter.ingest(samples: [sample(generation: "1")], deltas: delta(), currentInterface: "en0", connectionKnown: true)
        meter.ingest(samples: [sample(generation: "2")], deltas: delta(), currentInterface: "en0", connectionKnown: true)
        XCTAssertEqual(meter.reading()?.stopped, true)
        XCTAssertEqual(meter.reading()?.total, 0)
    }
    func testInvalidBudgetAndOverflowFailClosed() {
        var meter = ConnectionSessionMeter()
        XCTAssertFalse(meter.begin(label: "", gigabytes: 1, sample: sample()))
        XCTAssertFalse(meter.begin(label: "A", gigabytes: 10001, sample: sample()))
        XCTAssertTrue(meter.begin(label: "A", gigabytes: 1, sample: sample()))
        meter.ingest(samples: [sample()], deltas: delta(), currentInterface: "en0", connectionKnown: true)
        meter.ingest(samples: [sample()], deltas: delta(received: UInt64.max, sent: 1), currentInterface: "en0", connectionKnown: true)
        XCTAssertEqual(meter.reading()?.stopped, true)
        XCTAssertEqual(meter.reading()?.total, 0)
    }
}
