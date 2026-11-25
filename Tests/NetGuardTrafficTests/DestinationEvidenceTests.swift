import XCTest
import NetGuardTraffic

final class DestinationEvidenceTests: XCTestCase {
    func testIPv4AddressSemantics() {
        let cases: [(String, DestinationAddressKind)] = [
            ("127.0.0.1", .loopback), ("169.254.1.1", .linkLocal),
            ("10.0.0.1", .privateSpace), ("172.31.255.255", .privateSpace),
            ("192.168.1.1", .privateSpace), ("100.64.0.0", .sharedSpace),
            ("100.127.255.255", .sharedSpace), ("224.0.0.1", .multicast),
            ("192.0.2.1", .specialUse), ("198.18.0.1", .specialUse),
            ("203.0.113.1", .specialUse), ("255.255.255.255", .specialUse),
            ("8.8.8.8", .publicCandidate), ("172.32.0.1", .publicCandidate),
            ("100.128.0.1", .publicCandidate), ("invalid", .unknown),
            ("8.8.8.8:443", .unknown)
        ]
        for (address, expected) in cases {
            XCTAssertEqual(DestinationAddressKind.classify(address), expected, address)
        }
    }
    func testIPv6AndMappedIPv4() {
        let cases: [(String, DestinationAddressKind)] = [
            ("::", .specialUse), ("::1", .loopback), ("fe80::1", .linkLocal),
            ("fd12::1", .privateSpace), ("ff02::1", .multicast),
            ("2001:db8::1", .specialUse), ("2002::1", .specialUse),
            ("3fff::1", .specialUse), ("2606:4700::1111", .publicCandidate),
            ("::ffff:192.168.1.1", .privateSpace), ("::ffff:8.8.8.8", .publicCandidate),
            ("fe80::1%en0", .unknown), ("[::1]", .unknown), ("::1\0ignored", .unknown)
        ]
        for (address, expected) in cases {
            XCTAssertEqual(DestinationAddressKind.classify(address), expected, address)
        }
    }
    func testDirectionalAggregationAndUnknown() throws {
        let result = try XCTUnwrap(DestinationFlowProjection.summarize([
            .init(flowID: "1", remoteAddress: "10.0.0.1", received: 20, sent: 10),
            .init(flowID: "2", remoteAddress: "fd00::1", received: 5, sent: 7),
            .init(flowID: "3", remoteAddress: "8.8.8.8", received: 12, sent: 2),
            .init(flowID: "4", remoteAddress: "unknown", received: 4, sent: 0)
        ]))
        XCTAssertEqual(result[.privateSpace]?.received, 25)
        XCTAssertEqual(result[.privateSpace]?.sent, 17)
        XCTAssertEqual(result[.publicCandidate]?.total, 14)
        XCTAssertEqual(result[.unknown]?.total, 4)
        XCTAssertNil(result[.loopback])
    }
    func testRejectsAmbiguousAndOverflowingEvidence() {
        let one = DestinationFlowDelta(flowID: "a", remoteAddress: "10.0.0.1", received: UInt64.max, sent: 0)
        XCTAssertNil(DestinationFlowProjection.summarize([]))
        XCTAssertNil(DestinationFlowProjection.summarize([one, one]))
        XCTAssertNil(DestinationFlowProjection.summarize([one, .init(flowID: "b", remoteAddress: "8.8.8.8", received: 1, sent: 0)]))
        XCTAssertNil(DestinationFlowProjection.summarize([.init(flowID: "", remoteAddress: "10.0.0.1", received: 0, sent: 0)]))
        XCTAssertNil(DestinationFlowProjection.summarize([.init(flowID: "c", remoteAddress: "10.0.0.1", received: UInt64.max, sent: 1)]))
    }
}
