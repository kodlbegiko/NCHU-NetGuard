import XCTest
@testable import NetGuardCore

final class DiagnosticsTests: XCTestCase {
    func testPrioritizesStorageAndConnection() {
        let input = DiagnosticInput(connected: false, scope: .unknown, persistenceHealthy: false,
                                    sampleGapCount: 1, providerFresh: false)
        XCTAssertEqual(DiagnosticsEngine.findings(input), [.storageIssue, .connectionUnknown, .scopeUnknown, .incompleteSamples])
    }
    func testProviderOnlyAppliesToDorm() {
        let external = DiagnosticInput(connected: true, scope: .external, persistenceHealthy: true,
                                       sampleGapCount: 0, providerFresh: false)
        XCTAssertEqual(DiagnosticsEngine.findings(external), [.observing])
        let dorm = DiagnosticInput(connected: true, scope: .dorm, persistenceHealthy: true,
                                   sampleGapCount: 0, providerFresh: false)
        XCTAssertEqual(DiagnosticsEngine.findings(dorm), [.providerUnknown])
    }
}
