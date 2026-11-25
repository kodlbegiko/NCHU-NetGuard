import XCTest
import NetGuardCore

/// Literal JSON v1 golden fixtures. Public API only (no @testable).
final class ContractCompatibilityTests: XCTestCase {
    private func verify<T: ValidatedContract & Equatable>(_ type: T.Type, _ fixture: String) throws {
        let data = Data(fixture.utf8)
        let original = try T.decodeValidated(data)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try T.decodeValidated(encoded), original)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields["futureOptionalField"] = "ignored"
        XCTAssertEqual(try T.decodeValidated(JSONSerialization.data(withJSONObject: fields)), original)
        fields["schemaVersion"] = 2
        XCTAssertThrowsError(try T.decodeValidated(JSONSerialization.data(withJSONObject: fields))) {
            XCTAssertEqual($0 as? ContractError, .unsupportedVersion)
        }
        fields.removeValue(forKey: "schemaVersion")
        XCTAssertThrowsError(try T.decodeValidated(JSONSerialization.data(withJSONObject: fields)))
    }

    func testTrafficSnapshotV1() throws {
        try verify(TrafficSnapshot.self, #"{"schemaVersion":1,"timestamp":0,"interfaces":[{"interfaceID":"en0","received":100,"sent":50}],"quality":"measured"}"#)
    }

    func testNetworkSnapshotV1() throws {
        try verify(NetworkSnapshot.self, #"{"schemaVersion":1,"observedAt":0,"interfaces":[{"serviceID":"fixture-service","name":"en0","scope":"dorm","quality":"estimated"}]}"#)
    }

    func testQuotaProfileV1() throws {
        try verify(QuotaProfile.self, #"{"schemaVersion":1,"providerID":"fixture","scope":"dorm","receiveLimit":700,"sendLimit":400,"totalLimit":1100,"resetTimeZoneID":"Asia/Taipei","policySource":"fixture","policyVerified":false}"#)
    }

    func testPolicyDecisionV1() throws {
        try verify(PolicyDecision.self, #"{"schemaVersion":1,"decisionID":"00000000-0000-4000-8000-000000000001","kind":"observe","reason":"fixture","requiresAuthorization":false,"expiresAt":60}"#)
    }

    func testNetworkActionV1() throws {
        try verify(NetworkAction.self, #"{"schemaVersion":1,"transactionID":"00000000-0000-4000-8000-000000000001","operation":"changeOwnedRoute","targetServiceID":"fixture-service","preconditionDigest":"fixture","timeoutSeconds":10}"#)
    }

    func testRecoverySnapshotV1() throws {
        try verify(RecoverySnapshot.self, #"{"schemaVersion":1,"transactionID":"00000000-0000-4000-8000-000000000001","observedAt":0,"ownedConfiguration":{"fixture":"before"},"integrityDigest":"fixture"}"#)
    }

    func testProtectedWorkflowV1() throws {
        try verify(ProtectedWorkflow.self, #"{"schemaVersion":1,"workflowID":"00000000-0000-4000-8000-000000000001","processIdentity":"fixture","optedIn":false,"expiresAt":60}"#)
    }

    func testEventRecordV1() throws {
        try verify(EventRecord.self, #"{"schemaVersion":1,"eventID":"00000000-0000-4000-8000-000000000001","timestamp":0,"category":"fixture","redactedReason":"fixture","outcome":"observed"}"#)
    }
}
