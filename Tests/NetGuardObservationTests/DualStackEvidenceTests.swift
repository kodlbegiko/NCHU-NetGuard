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

    func testRouteFailureCategoriesAndRejectFlags() {
        XCTAssertEqual(DefaultRouteParser.inspect("").status, .emptyOutput)
        XCTAssertEqual(DefaultRouteParser.inspect("destination: default").status, .missingInterface)
        XCTAssertEqual(DefaultRouteParser.inspect("interface: en0\ninterface: en0").status, .ambiguousInterface)
        XCTAssertEqual(DefaultRouteParser.inspect("interface: invalid name").status, .invalidInterface)
        XCTAssertEqual(DefaultRouteParser.inspect(String(repeating: "a", count: 65537)).status, .outputLimit)
        XCTAssertEqual(DefaultRouteParser.inspect("interface: en0\nflags: <UP,REJECT>").status, .invalidRouteFlags)
        XCTAssertNil(DefaultRouteParser.interfaceName("interface: en0\nflags: <UP,BLACKHOLE>"))
        XCTAssertEqual(DefaultRouteParser.inspect("interface : en0\nflags: <UP,GATEWAY>").interfaceName, "en0")
    }

    func testExactAbsentDefaultRouteDiagnosticIsNotMalformedOrReachable() {
        for text in ["not in table", "route: not in table", "route: writing to routing socket: not in table\n"] {
            XCTAssertEqual(DefaultRouteParser.inspect(text).status, .noDefaultRoute)
            XCTAssertNil(DefaultRouteParser.interfaceName(text))
        }
        XCTAssertEqual(DefaultRouteParser.inspect("").status, .emptyOutput)
        XCTAssertEqual(DefaultRouteParser.inspect("route: permission denied").status, .missingInterface)
        XCTAssertNotEqual(DefaultRouteParser.inspect("interface: en0\nroute: not in table").status, .parsed)
        XCTAssertNotEqual(DefaultRouteParser.inspect("unrecognized not in table").status, .noDefaultRoute)
    }

    func testRouteCandidatesRequireStableEvidenceAndMatchingInterface() {
        let direct = RoutePathParser.inspect("interface: en0\nflags: <UP,HOST,DONE>\n")
        let gateway = RoutePathParser.inspect("interface: en0\nflags: <UP,GATEWAY,DONE>\ngateway: 192.0.2.1\n")
        XCTAssertEqual(direct?.kind, .directLinkCandidate)
        XCTAssertEqual(gateway?.kind, .gatewayCandidate)
        XCTAssertEqual(RoutePathParser.classify(before: gateway, after: gateway, flowInterface: "en0", tunnelOverlap: false), .gatewayCandidate)
        XCTAssertEqual(RoutePathParser.classify(before: direct, after: gateway, flowInterface: "en0", tunnelOverlap: false), .unknown)
        XCTAssertEqual(RoutePathParser.classify(before: direct, after: direct, flowInterface: "en1", tunnelOverlap: false), .unknown)
        XCTAssertEqual(RoutePathParser.classify(before: direct, after: direct, flowInterface: "en0", tunnelOverlap: true), .unknown)
        XCTAssertNil(RoutePathParser.inspect("interface: utun4\nflags: <UP,HOST>"))
        XCTAssertNil(RoutePathParser.inspect("interface: en0\nflags: <UP,GATEWAY>"))
        XCTAssertNil(RoutePathParser.inspect("interface: en0\nflags: <UP,REJECT>"))
        XCTAssertNil(RoutePathParser.inspect("interface: en0"))
    }

}
