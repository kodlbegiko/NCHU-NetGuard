import XCTest
import NetGuardCore

final class ContractSemanticTests: XCTestCase {
    func testOversizedDocumentRejected() {
        XCTAssertThrowsError(try TrafficSnapshot.decodeValidated(Data(repeating: 32, count: 1_048_577))) {
            XCTAssertEqual($0 as? ContractError, .oversizedDocument)
        }
    }
    func testMeasuredEmptyAndUnboundedInterfacesRejected() throws {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertThrowsError(try TrafficSnapshot(timestamp: date, interfaces: [], quality: .measured).validate())
        try TrafficSnapshot(timestamp: date, interfaces: [], quality: .unknown).validate()
        let many = (0..<257).map { InterfaceCounters(interfaceID: "fixture-\($0)", received: 0, sent: 0) }
        XCTAssertThrowsError(try TrafficSnapshot(timestamp: date, interfaces: many, quality: .measured).validate())
    }
    func testDecisionExpiryIsNotStructuralFailure() throws {
        let expiry = Date(timeIntervalSinceReferenceDate: 100)
        let decision = PolicyDecision(decisionID: UUID(), kind: .observe, reason: "fixture",
                                      requiresAuthorization: false, expiresAt: expiry)
        try decision.validate()
        XCTAssertTrue(decision.isCurrent(at: expiry.addingTimeInterval(-1)))
        XCTAssertFalse(decision.isCurrent(at: expiry))
    }
    func testWorkflowRequiresConsentAndCurrentExpiry() {
        let expiry = Date(timeIntervalSinceReferenceDate: 100)
        let now = expiry.addingTimeInterval(-1)
        let enabled = ProtectedWorkflow(workflowID: UUID(), processIdentity: "fixture", optedIn: true, expiresAt: expiry)
        let disabled = ProtectedWorkflow(workflowID: UUID(), processIdentity: "fixture", optedIn: false, expiresAt: expiry)
        XCTAssertTrue(enabled.isOptedIn(at: now))
        XCTAssertFalse(enabled.isOptedIn(at: expiry))
        XCTAssertFalse(disabled.isOptedIn(at: now))
    }
    func testControlCharactersAndExcessiveFieldsRejected() {
        let action = NetworkAction(transactionID: UUID(), operation: .changeOwnedRoute,
            targetServiceID: "fixture\ninvalid", preconditionDigest: "fixture", timeoutSeconds: 10)
        XCTAssertThrowsError(try action.validate())
        let recovery = RecoverySnapshot(transactionID: UUID(), observedAt: Date(),
            ownedConfiguration: ["fixture": String(repeating: "a", count: 4097)], integrityDigest: "fixture")
        XCTAssertThrowsError(try recovery.validate())
    }
}
