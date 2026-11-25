import XCTest
import NetGuardObservation

final class ObservationScheduleTests: XCTestCase {
    func testEventCoalescingAndFallback() {
        var s = ObservationSchedule()
        XCTAssertTrue(s.takeRoute(now: 0, visible: false))
        XCTAssertFalse(s.takeRoute(now: 1, visible: false))
        s.networkChanged()
        XCTAssertFalse(s.takeRoute(now: 1, visible: false))
        XCTAssertTrue(s.takeRoute(now: 2, visible: false))
        XCTAssertFalse(s.takeRoute(now: 31, visible: false))
        XCTAssertTrue(s.takeRoute(now: 32, visible: false))
    }
    func testOptionalProbesRespectFocusAndVisibility() {
        var s = ObservationSchedule()
        XCTAssertFalse(s.takeApps(now: 0, visible: false, busy: true, allowed: true))
        XCTAssertFalse(s.takePing(now: 0, visible: true, busy: true, allowed: false))
        XCTAssertTrue(s.takeApps(now: 0, visible: true, busy: false, allowed: true))
        XCTAssertFalse(s.takeApps(now: 10, visible: true, busy: false, allowed: true))
        XCTAssertTrue(s.takeApps(now: 10, visible: true, busy: true, allowed: true))
        XCTAssertTrue(s.takePing(now: 0, visible: true, busy: true, allowed: true))
        XCTAssertFalse(s.takePing(now: 14, visible: true, busy: true, allowed: true))
        XCTAssertTrue(s.takePing(now: 15, visible: true, busy: true, allowed: true))
    }
    func testInvalidClockAndTunnelEvidence() {
        var s = ObservationSchedule()
        XCTAssertFalse(s.takeRoute(now: .nan, visible: true))
        XCTAssertTrue(TunnelEvidence.isTunnelCandidate("utun3"))
        XCTAssertFalse(TunnelEvidence.isTunnelCandidate("utun"))
        XCTAssertFalse(TunnelEvidence.isTunnelCandidate("en0"))
        XCTAssertFalse(TunnelEvidence.isTunnelCandidate("utun-1"))
        XCTAssertTrue(TunnelEvidence.description(defaultInterface: "en0", candidates: ["utun3"]).contains("不代表"))
        XCTAssertTrue(TunnelEvidence.description(defaultInterface: "utun3", candidates: []).contains("未確認"))
    }
}
