import XCTest
@testable import NetGuardCore

final class ContractValidationTests: XCTestCase {
    func testQuotaRoundTripAndUnsupportedVersion() throws {
        let profile = QuotaProfile(providerID: "fixture", scope: .dorm, receiveLimit: 700,
            sendLimit: 400, totalLimit: 1100, resetTimeZoneID: "Asia/Taipei",
            policySource: "fixture", policyVerified: false)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try QuotaProfile.decodeValidated(data), profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try QuotaProfile.decodeValidated(JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual($0 as? ContractError, .unsupportedVersion)
        }
    }
    func testInvalidQuotaAndDuplicateInterfaces() throws {
        let p = QuotaProfile(providerID: "fixture", scope: .dorm, receiveLimit: 0,
            sendLimit: 400, totalLimit: 1100, resetTimeZoneID: "Asia/Taipei",
            policySource: "fixture", policyVerified: true)
        XCTAssertThrowsError(try p.validate())
        let i = InterfaceCounters(interfaceID: "en0", received: 1, sent: 1)
        let s = TrafficSnapshot(timestamp: Date(), interfaces: [i,i], quality: .measured)
        XCTAssertThrowsError(try s.validate())
    }
    func testInvalidActionAndAuthorizationDecision() throws {
        let id = UUID().uuidString
        let action = """
        {"schemaVersion":1,"transactionID":"\(id)","operation":"changeOwnedRoute","targetServiceID":"","preconditionDigest":"fixture","timeoutSeconds":0}
        """
        XCTAssertThrowsError(try NetworkAction.decodeValidated(Data(action.utf8)))
        let decision = """
        {"schemaVersion":1,"decisionID":"\(id)","kind":"requestAuthorization","reason":"fixture","requiresAuthorization":false,"expiresAt":0}
        """
        XCTAssertThrowsError(try PolicyDecision.decodeValidated(Data(decision.utf8)))
    }
}
