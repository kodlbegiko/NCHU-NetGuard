import XCTest
@testable import NetGuardCore

final class ProbeQualityTests: XCTestCase {
    func testProbeSuccessAndFailure() {
        XCTAssertEqual(ProbeRunner.run("/usr/bin/printf", ["hello"]), .success("hello"))
        XCTAssertEqual(ProbeRunner.run("/usr/bin/false", []), .failed)
    }
    func testProbeTimeoutAndOutputLimit() {
        XCTAssertEqual(ProbeRunner.run("/bin/sleep", ["2"], timeout: 0.1), .timedOut)
        XCTAssertEqual(ProbeRunner.run("/usr/bin/printf", ["abcdef"], maxBytes: 3), .outputLimit)
    }
    func testExactLimitAndUnboundedProducer() {
        XCTAssertEqual(ProbeRunner.run("/usr/bin/printf", ["abc"], maxBytes: 3), .success("abc"))
        XCTAssertEqual(ProbeRunner.run("/usr/bin/yes", [], timeout: 2, maxBytes: 32_768), .outputLimit)
        XCTAssertEqual(ProbeRunner.run("/usr/bin/false", [], acceptedExitCodes: [1]), .success(""))
    }
    func testBoundedOptionalDiagnosticCapture() {
        // Fixed test-only shell fixture; production route arguments remain allowlisted.
        let args = ["-c", "printf 'not in table' >&2"]
        XCTAssertEqual(ProbeRunner.run("/bin/sh", args), .success(""))
        XCTAssertEqual(ProbeRunner.run("/bin/sh", args, mergeStandardError: true), .success("not in table"))
        XCTAssertEqual(ProbeRunner.run("/bin/sh", args, maxBytes: 3, mergeStandardError: true), .outputLimit)
        XCTAssertFalse(ProbeRunner.isApproved("/bin/sh", args))
    }
    func testProductionProbeArgumentPolicy() {
        XCTAssertTrue(ProbeRunner.isApproved("/sbin/route", ["-n", "get", "-inet", "192.0.2.1"]))
        XCTAssertTrue(ProbeRunner.isApproved("/sbin/route", ["-n", "get", "-inet6", "2001:db8::1"]))
        XCTAssertTrue(ProbeRunner.isApproved("/usr/sbin/ipconfig", ["getifaddr", "en0"]))
        XCTAssertFalse(ProbeRunner.isApproved("/sbin/route", ["add", "default", "192.0.2.1"]))
        XCTAssertFalse(ProbeRunner.isApproved("/sbin/route", ["-n", "get", "-inet", "-bad"]))
        XCTAssertFalse(ProbeRunner.isApproved("/usr/sbin/ipconfig", ["getifaddr", "en0;bad"]))
        XCTAssertFalse(ProbeRunner.isApproved("/usr/bin/osascript", ["-e", "do shell script \"anything\""]))
        XCTAssertFalse(ProbeRunner.isApproved("/usr/bin/python3", ["/tmp/unknown.py", "--json"]))
        XCTAssertEqual(ProbeRunner.runApproved("/usr/bin/printf", ["hello"]), .failed)
    }
    func testQualityRequiresFreshSamples() {
        var window = NetworkQualityWindow()
        window.ingest(latency: 20, uptime: 10)
        window.ingest(latency: 200, uptime: 20)
        XCTAssertEqual(window.state(at: 20), .unknown)
        window.ingest(latency: 70, uptime: 30)
        XCTAssertEqual(window.state(at: 30), .elevatedLatency)
        XCTAssertEqual(window.state(at: 151), .unknown)
        window.ingest(latency: nil, uptime: 152)
        XCTAssertEqual(window.state(at: 152), .unknown)
    }
    func testAppParserRejectsMalformedAndOverflow() {
        let rows = AppTrafficParser.parse("App.12,100,200,\nApp.13,3,4,\nBad.1,-1,0,\nOverflow.1,18446744073709551615,1,\n")
        XCTAssertEqual(rows, [AppTrafficObservation(name: "App", bytes: 307)])
    }
}
