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
        let emitted = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(emitted.keys), Set(fields.keys), "v1 wire field set changed")
        XCTAssertEqual(emitted as NSDictionary, fields as NSDictionary, "v1 wire values changed")
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

    func testPublicConstruction() throws {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let id = UUID()
        try NetworkSnapshot(observedAt: date, interfaces: [
            .init(serviceID: "fixture", name: "en0", scope: .dorm, quality: .estimated)
        ]).validate()
        try PolicyDecision(decisionID: id, kind: .observe, reason: "fixture",
                           requiresAuthorization: false, expiresAt: date).validate()
        try NetworkAction(transactionID: id, operation: .changeOwnedRoute, targetServiceID: "fixture",
                          preconditionDigest: "fixture", timeoutSeconds: 10).validate()
        try RecoverySnapshot(transactionID: id, observedAt: date, ownedConfiguration: ["fixture":"before"],
                             integrityDigest: "fixture").validate()
        try ProtectedWorkflow(workflowID: id, processIdentity: "fixture", optedIn: false, expiresAt: date).validate()
        try EventRecord(eventID: id, timestamp: date, correlationID: nil, category: "fixture",
                        redactedReason: "fixture", outcome: "observed", errorCode: nil).validate()
    }

    func testCoreScopeFacadeExportsNewTrafficHelpers() throws {
        XCTAssertEqual(InterfaceScopeEvidence.resolve(ipv4: ["140.120.1.2"],
            hasUsableIPv6: false, isWiFi: false), .unknown)
        let sample = ScopedInterfaceSample(counters: .init(interfaceID: "en0",
            received: 0, sent: 0), scope: .unknown, identity: "fixture", counterGeneration: "1")
        let selection = try XCTUnwrap(ManualScopeSelection(scope: .dorm, sample: sample))
        XCTAssertTrue(selection.matches(sample))
    }

}
