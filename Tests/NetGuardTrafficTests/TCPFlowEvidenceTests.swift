import Foundation
import XCTest
import NetGuardTraffic

final class TCPFlowEvidenceTests: XCTestCase {
    private let starts = [42: "Mon Nov 23 12:00:00 2026"]
    private let header = ",bytes_in,bytes_out,interface,state,\n"
    private let parent = "Example.42,1000,2000,,,\n"
    private func flow(_ received: UInt64 = 100, _ sent: UInt64 = 50, remote: String = "8.8.8.8:443", iface: String = "en0") -> String {
        "  tcp4 192.168.1.2:50000<->\(remote),\(received),\(sent),\(iface),Established,\n"
    }
    private func parse(_ text: String) -> [TCPFlowCounter]? {
        TCPFlowParser.parse(text, before: starts, after: starts)
    }

    func testProcessSummariesNeverCountAndColumnOrderIsExplicit() throws {
        let rows = try XCTUnwrap(parse(header + parent + flow()))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.received, 100)
        XCTAssertEqual(rows.first?.sent, 50)
        XCTAssertEqual(rows.first?.remote, "8.8.8.8")
        let reordered = ",state,interface,bytes_out,bytes_in,\nExample.42,,,2000,1000,\n  tcp4 192.168.1.2:50000<->8.8.8.8:443,Established,en0,50,100,\n"
        XCTAssertEqual(parse(reordered), rows)
    }

    func testUnstableOwnerAndAmbiguousOrUnsupportedRowsExcluded() {
        let data = header + parent + flow()
        XCTAssertEqual(TCPFlowParser.parse(data, before: starts, after: [42: "changed"])?.count, 0)
        XCTAssertEqual(parse(data + flow())?.count, 0)
        XCTAssertEqual(parse(header + parent + flow(remote: "*:*"))?.count, 0)
        XCTAssertEqual(parse(header + parent + flow(remote: "8.8.8.8:443").replacingOccurrences(of: "Established", with: "Listen"))?.count, 0)
        XCTAssertEqual(parse(header + parent + flow().replacingOccurrences(of: "tcp4 ", with: "tcp6 "))?.count, 0)
        XCTAssertNil(parse(header + parent + flow() + header))
        XCTAssertNil(parse("unsupported\n"))
    }

    func testOnlyAdjacentMatchedMonotonicCountersProduceDeltas() {
        var accumulator = TCPFlowAccumulator()
        XCTAssertNil(accumulator.ingest(parse(header + parent + flow()), uptime: 1))
        let totals = accumulator.ingest(parse(header + parent + flow(120, 80)), uptime: 2)
        XCTAssertEqual(totals?[.publicCandidate]?.received, 20)
        XCTAssertEqual(totals?[.publicCandidate]?.sent, 30)
        XCTAssertNil(accumulator.ingest(parse(header + parent + flow(1, 1)), uptime: 3))
        XCTAssertNil(accumulator.ingest(parse(header + parent + flow(100, 100, iface: "en1")), uptime: 4))
        XCTAssertNil(accumulator.ingest(parse(header + parent + flow(120, 120, iface: "en1")), uptime: 25))
        XCTAssertNil(accumulator.ingest(nil, uptime: 26))
        XCTAssertNil(accumulator.ingest(parse(header + parent + flow(200, 200, iface: "en1")), uptime: 27))
    }
}
