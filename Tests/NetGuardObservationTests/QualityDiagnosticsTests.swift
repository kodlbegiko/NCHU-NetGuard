import XCTest
import NetGuardObservation

final class QualityDiagnosticsTests: XCTestCase {
    func testCompletedEchoLossUsesCountsNotDisplayedPercentage() throws {
        let output = """
        2 packets transmitted, 1 packets received, 50.0% packet loss
        round-trip min/avg/max/stddev = 12.000/12.000/12.000/0.000 ms
        """
        let reading = try XCTUnwrap(EchoProbeParser.parse(output, expectedCount: 2))
        XCTAssertEqual(reading.sent, 2)
        XCTAssertEqual(reading.received, 1)
        XCTAssertEqual(reading.lossFraction, 0.5)
        XCTAssertEqual(reading.averageMilliseconds, 12)
        XCTAssertNil(EchoProbeParser.parse(output, expectedCount: 3))
        XCTAssertNil(EchoProbeParser.parse("ping: sendto: No route to host", expectedCount: 2))
    }

    func testNoRepliesIsDistinctFromUnknown() throws {
        let reading = try XCTUnwrap(EchoProbeParser.parse("2 packets transmitted, 0 packets received, 100.0% packet loss", expectedCount: 2))
        XCTAssertEqual(reading.lossFraction, 1)
        XCTAssertNil(reading.averageMilliseconds)
        XCTAssertNil(EchoProbeParser.parse("2 packets transmitted, 3 packets received, 0.0% packet loss", expectedCount: 2))
        XCTAssertNil(EchoProbeParser.parse("2 packets transmitted, 1 packets received, 50.0% packet loss", expectedCount: 2))
    }

    func testWeightedWindowAndFreshness() throws {
        let one = try XCTUnwrap(EchoProbeParser.parse("2 packets transmitted, 1 packets received, 50.0% packet loss\nround-trip min/avg/max/stddev = 10/10/10/0 ms", expectedCount: 2))
        let two = try XCTUnwrap(EchoProbeParser.parse("2 packets transmitted, 2 packets received, 0.0% packet loss\nround-trip min/avg/max/stddev = 20/25/30/5 ms", expectedCount: 2))
        var window = EchoProbeWindow()
        window.ingest(one, at: 1)
        window.ingest(two, at: 30)
        let summary = try XCTUnwrap(window.summary(at: 31))
        XCTAssertEqual(summary.lossFraction, 0.25)
        XCTAssertEqual(summary.averageMilliseconds, 20)
        XCTAssertNil(window.summary(at: 151))
        window.ingest(nil, at: 32)
        XCTAssertNil(window.summary(at: 32))
    }

    func testDNSResponseStatusIsNotResolutionSuccess() throws {
        let output = ";; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 123\n;; Query time: 22 msec\n"
        let reading = try XCTUnwrap(DNSProbeParser.parse(output))
        XCTAssertEqual(reading.status, "NXDOMAIN")
        XCTAssertEqual(reading.milliseconds, 22)
        XCTAssertNil(DNSProbeParser.parse(";; Query time: 0 msec"))
        XCTAssertNil(DNSProbeParser.parse(output + ";; Query time: 30 msec\n"))
    }
}
