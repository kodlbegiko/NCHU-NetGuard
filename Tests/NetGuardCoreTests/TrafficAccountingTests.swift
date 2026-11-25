import XCTest
@testable import NetGuardCore

final class TrafficAccountingTests: XCTestCase {
    private func sample(_ id: String, _ rx: UInt64, _ tx: UInt64) -> InterfaceCounters {
        InterfaceCounters(interfaceID: id, received: rx, sent: tx)
    }
    func testIndependentInterfaces() {
        var engine = CounterAccumulator()
        XCTAssertEqual(engine.ingest([sample("en0", 100, 10), sample("en6", 200, 20)])["en0"]?.quality, .unknown)
        let d = engine.ingest([sample("en0", 150, 13), sample("en6", 220, 29)])
        XCTAssertEqual(d["en0"]?.received, 50)
        XCTAssertEqual(d["en6"]?.received, 20)
        XCTAssertEqual(d["en6"]?.sent, 9)
        XCTAssertEqual(d["en6"]?.quality, .measured)
    }
    func testResetAndReattach() {
        var engine = CounterAccumulator()
        _ = engine.ingest([sample("en0", 1000, 100)])
        XCTAssertEqual(engine.ingest([sample("en0", 10, 1)])["en0"]?.quality, .unknown)
        _ = engine.ingest([])
        XCTAssertEqual(engine.ingest([sample("en0", 20, 2)])["en0"]?.quality, .unknown)
    }
    func testDuplicateIdentityInvalidatesBaseline() {
        var engine = CounterAccumulator()
        _ = engine.ingest([sample("en0", 1, 1)])
        XCTAssertEqual(engine.ingest([sample("en0", 2, 2), sample("en0", 3, 3)])["en0"]?.quality, .unknown)
        XCTAssertEqual(engine.ingest([sample("en0", 4, 4)])["en0"]?.quality, .unknown)
    }
}
