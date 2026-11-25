import XCTest
import NetGuardObservation

final class ProcessUsageTests: XCTestCase {
    private func row(_ pid: Int, _ received: UInt64, _ sent: UInt64, start: String = "a", name: String = "App") -> ProcessCounter {
        .init(pid: pid, name: name, start: start, received: received, sent: sent)
    }
    func testIdentityEvidenceAndHeader() throws {
        let before = ProcessCounterParser.starts("42 Wed Nov 25 12:00:00 2026\n43 Wed Nov 25 12:00:01 2026\n")
        let after = ProcessCounterParser.starts("42 Wed Nov 25 12:00:00 2026\n43 Wed Nov 25 12:00:02 2026\n")
        let rows = try XCTUnwrap(ProcessCounterParser.parse(",bytes_in,bytes_out,\nExample.42,10,20,\nOther.43,100,200,\n", before: before, after: after))
        XCTAssertEqual(rows.map(\.pid), [42])
        XCTAssertEqual(rows.first?.received, 10)
        XCTAssertNil(ProcessCounterParser.parse("Example.42,10,20", before: before, after: after))
    }
    func testOnlyDeltasAreAccumulatedAndDirectionsPreserved() {
        var engine = ProcessUsageAccumulator()
        engine.ingest([row(1, 100, 20), row(2, 50, 10)], uptime: 1)
        XCTAssertTrue(engine.report().rows.isEmpty)
        engine.ingest([row(1, 110, 25), row(2, 60, 11)], uptime: 2)
        XCTAssertEqual(engine.report().rows.first?.received, 20)
        XCTAssertEqual(engine.report().rows.first?.sent, 6)
        engine.ingest([row(1, 110, 25), row(2, 60, 11)], uptime: 3)
        XCTAssertEqual(engine.report().rows.first?.total, 26)
        XCTAssertEqual(engine.report().measuredIntervals, 2)
    }
    func testReuseResetPauseAndMissingProcessCannotInventUsage() {
        var engine = ProcessUsageAccumulator()
        engine.ingest([row(1, 10, 10)], uptime: 1)
        engine.ingest([row(1, 20, 20, start: "b")], uptime: 2)
        engine.ingest([row(1, 5, 5, start: "b")], uptime: 3)
        engine.ingest([], uptime: 4)
        engine.ingest([row(1, 100, 100, start: "b")], uptime: 5)
        engine.breakContinuity()
        engine.ingest([row(1, 200, 200, start: "b")], uptime: 6)
        engine.ingest([row(1, 300, 300, start: "b")], uptime: 60)
        XCTAssertTrue(engine.report().rows.isEmpty)
        XCTAssertEqual(engine.report().measuredIntervals, 0)
    }
    func testDuplicatePIDAndOverflowFailClosed() {
        var engine = ProcessUsageAccumulator()
        engine.ingest([row(1, 0, 0)], uptime: 1)
        engine.ingest([row(1, 10, 10), row(1, 20, 20)], uptime: 2)
        engine.ingest([row(1, 0, 0)], uptime: 3)
        engine.ingest([row(1, UInt64.max, 1)], uptime: 4)
        XCTAssertTrue(engine.report().rows.isEmpty)
        XCTAssertTrue(engine.report().capacityReached)
    }

    func testMatchedDurationExcludesGapsAndResets() {
        var engine = ProcessUsageAccumulator()
        engine.ingest([row(1, 10, 10)], uptime: 1)
        engine.ingest([row(1, 20, 20)], uptime: 21)
        XCTAssertEqual(engine.report().matchedIntervalSeconds, 20)
        engine.ingest(nil, uptime: 25)
        engine.ingest([row(1, 50, 50)], uptime: 40)
        engine.ingest([row(1, 60, 60)], uptime: 75)
        XCTAssertEqual(engine.report().matchedIntervalSeconds, 55)
        engine.ingest([row(1, 70, 70)], uptime: 130)
        engine.breakContinuity()
        engine.ingest([row(1, 80, 80)], uptime: 135)
        XCTAssertEqual(engine.report().matchedIntervalSeconds, 55)
        XCTAssertEqual(engine.report().measuredIntervals, 2)
    }

}
