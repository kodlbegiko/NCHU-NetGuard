import XCTest
import NetGuardObservation

final class ObservationScheduleTests: XCTestCase {
    func testInterfaceMetadataCacheRefreshesOnIdentityTimeAndInvalidation() {
        var cache = InterfaceMetadataCache()
        var loads = 0
        var kinds = ["en0": "WiFi", "en9": "Ethernet"]
        let inventory: [String: UInt32] = ["en0": 4, "utun0": 5]
        func load() -> [String: String] { loads += 1; return kinds }
        XCTAssertEqual(cache.resolve(inventory: inventory, now: 0, load: load), ["en0": "WiFi"])
        XCTAssertEqual(cache.resolve(inventory: inventory, now: 9, load: load), ["en0": "WiFi"])
        XCTAssertEqual(loads, 1)
        kinds = ["en0": "Ethernet"]
        XCTAssertEqual(cache.resolve(inventory: inventory, now: 10, load: load), kinds)
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(cache.resolve(inventory: ["en0": 8], now: 11, load: load), kinds)
        XCTAssertEqual(loads, 3)
        XCTAssertEqual(cache.resolve(inventory: ["en0": 8], now: 9, load: load), kinds)
        XCTAssertEqual(loads, 4)
        cache.invalidate()
        XCTAssertEqual(cache.resolve(inventory: inventory, now: 12, load: load), kinds)
        XCTAssertEqual(loads, 5)
        kinds = [:]
        XCTAssertEqual(cache.resolve(inventory: inventory, now: 22, load: load), [:])
        XCTAssertEqual(cache.resolve(inventory: inventory, now: 23, load: load), [:])
        XCTAssertEqual(loads, 7)
        XCTAssertEqual(cache.resolve(inventory: [:], now: 24, load: load), [:])
        XCTAssertEqual(cache.resolve(inventory: ["en0": 0], now: 24, load: load), [:])
        XCTAssertEqual(cache.resolve(inventory: inventory, now: .nan, load: load), [:])
        XCTAssertEqual(loads, 7)
    }
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

    func testBackgroundCadenceRequiresConsentAndRespectsPause() {
        var s = ObservationSchedule()
        XCTAssertFalse(s.takeApps(now: 0, visible: false, busy: true, allowed: true))
        XCTAssertTrue(s.takeApps(now: 0, visible: false, busy: true, allowed: true, backgroundEnabled: true))
        XCTAssertFalse(s.takeApps(now: 19, visible: false, busy: true, allowed: true, backgroundEnabled: true))
        XCTAssertTrue(s.takeApps(now: 20, visible: false, busy: true, allowed: true, backgroundEnabled: true))
        XCTAssertFalse(s.takeApps(now: 55, visible: false, busy: false, allowed: false, backgroundEnabled: true))
        XCTAssertTrue(s.takeApps(now: 55, visible: false, busy: false, allowed: true, backgroundEnabled: true))
        XCTAssertFalse(s.takePing(now: 55, visible: false, busy: true, allowed: true))
    }

}
