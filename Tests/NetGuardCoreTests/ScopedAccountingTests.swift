import XCTest
@testable import NetGuardCore

final class ScopedAccountingTests: XCTestCase {
    func s(_ id: String, _ n: UInt64, _ scope: NetworkScope, _ identity: String = "a") -> ScopedInterfaceSample {
        ScopedInterfaceSample(counters: InterfaceCounters(interfaceID: id, received: n, sent: n),
                              scope: scope, identity: identity)
    }
    func testIndependentScopesAndChangedIdentity() {
        var engine = ScopedCounterAccumulator()
        _ = engine.ingest([s("en0", 100, .campusWifi), s("en6", 200, .dorm)], day: "d", uptime: 1)
        let d = engine.ingest([s("en0", 110, .campusWifi), s("en6", 230, .dorm)], day: "d", uptime: 2)
        XCTAssertEqual(d["en0"]?.delta.received, 10)
        XCTAssertEqual(d["en6"]?.scope, .dorm)
        XCTAssertEqual(d["en6"]?.delta.received, 30)
        let changed = engine.ingest([s("en0", 120, .campusWifi, "b")], day: "d", uptime: 3)
        XCTAssertEqual(changed["en0"]?.scope, .unknown)
        XCTAssertEqual(changed["en0"]?.delta.received, 10)
    }
    func testGapAndMidnight() {
        var engine = ScopedCounterAccumulator()
        _ = engine.ingest([s("en0", 10, .external)], day: "d", uptime: 1)
        XCTAssertEqual(engine.ingest([s("en0", 30, .external)], day: "d", uptime: 8)["en0"]?.delta.quality, .unknown)
        XCTAssertEqual(engine.ingest([s("en0", 40, .external)], day: "e", uptime: 9)["en0"]?.delta.quality, .unknown)
    }
    func testQuotaUsesSeparateLimitsAndUnknown() {
        let p = QuotaProfile(providerID: "test", scope: .dorm, receiveLimit: 700, sendLimit: 400,
                             totalLimit: 1100, resetTimeZoneID: "Asia/Taipei", policySource: "fixture", policyVerified: true)
        XCTAssertEqual(QuotaEvaluator.assess(profile: p, received: 0, sent: 380, quality: .measured), .critical)
        XCTAssertEqual(QuotaEvaluator.assess(profile: p, received: 490, sent: 0, quality: .measured), .warning)
        XCTAssertEqual(QuotaEvaluator.assess(profile: p, received: 0, sent: 0, quality: .unknown), .unknown)
    }
}
