import XCTest
import NetGuardObservation

final class DualStackEvidenceTests: XCTestCase {
    func testRouteParserRejectsAmbiguityAndMalformedNames() {
        XCTAssertEqual(DefaultRouteParser.interfaceName("route to: default\n  interface: en0\n"), "en0")
        XCTAssertEqual(DefaultRouteParser.interfaceName("destination: default\n  interface: utun4\n"), "utun4")
        XCTAssertNil(DefaultRouteParser.interfaceName("interface: en0\ninterface: en1"))
        XCTAssertNil(DefaultRouteParser.interfaceName("interface: en0; invalid"))
        XCTAssertNil(DefaultRouteParser.interfaceName("route: not found"))
    }
    func testDualStackDifferentInterfacesAndTunnelHint() {
        let evidence = DualStackEvidence(ipv4Interface: "en0", ipv6Interface: "utun4", observedAt: 10)
        XCTAssertTrue(evidence.description(at: 20).contains("不同介面"))
        XCTAssertTrue(evidence.tunnelDescription(at: 20, candidates: []).contains("疑似隧道"))
        XCTAssertFalse(evidence.isFresh(at: 71))
        XCTAssertFalse(evidence.isFresh(at: 9))
        XCTAssertTrue(evidence.description(at: 71).contains("過期"))
    }
    func testIPv6OnlyObservationDoesNotInventIPv4() {
        let evidence = DualStackEvidence(ipv4Interface: nil, ipv6Interface: "en0", observedAt: 10)
        XCTAssertTrue(evidence.description(at: 10).contains("IPv4：未確認"))
        XCTAssertTrue(evidence.description(at: 10).contains("IPv6：en0"))
    }
    func testLinkLocalAndNonLinkLocalRemainDistinct() {
        var evidence = InterfaceAddressEvidence()
        evidence.observeIPv6(linkLocal: true)
        XCTAssertTrue(evidence.description.contains("僅觀測到 link-local"))
        XCTAssertFalse(evidence.hasNonLinkLocalIPv6)
        evidence.observeIPv4()
        evidence.observeIPv6(linkLocal: false)
        XCTAssertTrue(evidence.hasIPv4)
        XCTAssertTrue(evidence.hasNonLinkLocalIPv6)
    }
}
