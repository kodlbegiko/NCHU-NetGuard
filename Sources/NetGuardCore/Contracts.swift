import Foundation

public struct NetworkSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let observedAt: Date
    public let interfaces: [Interface]
    public struct Interface: Codable, Equatable, Sendable {
        public let serviceID: String
        public let name: String
        public let scope: NetworkScope
        public let quality: SampleQuality
    }
}

public struct QuotaProfile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let providerID: String
    public let scope: NetworkScope
    public let receiveLimit: UInt64
    public let sendLimit: UInt64
    public let totalLimit: UInt64
    public let resetTimeZoneID: String
    public let policySource: String
    public let policyVerified: Bool

    public init(providerID: String, scope: NetworkScope, receiveLimit: UInt64,
                sendLimit: UInt64, totalLimit: UInt64, resetTimeZoneID: String,
                policySource: String, policyVerified: Bool) {
        self.schemaVersion = 1
        self.providerID = providerID
        self.scope = scope
        self.receiveLimit = receiveLimit
        self.sendLimit = sendLimit
        self.totalLimit = totalLimit
        self.resetTimeZoneID = resetTimeZoneID
        self.policySource = policySource
        self.policyVerified = policyVerified
    }
}

public enum DecisionKind: String, Codable, Sendable { case observe, notify, deferAction, requestAuthorization }
public struct PolicyDecision: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let decisionID: UUID
    public let kind: DecisionKind
    public let reason: String
    public let requiresAuthorization: Bool
    public let expiresAt: Date
}

public enum NetworkOperation: String, Codable, Sendable { case changeServiceOrder, changeOwnedRoute }
/// A plan is data, never authority to mutate the host.
public struct NetworkAction: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let transactionID: UUID
    public let operation: NetworkOperation
    public let targetServiceID: String
    public let preconditionDigest: String
    public let timeoutSeconds: UInt32
}
public struct RecoverySnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let transactionID: UUID
    public let observedAt: Date
    public let ownedConfiguration: [String: String]
    public let integrityDigest: String
}
public struct ProtectedWorkflow: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let workflowID: UUID
    public let processIdentity: String
    public let optedIn: Bool
    public let expiresAt: Date
}
public struct EventRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID
    public let timestamp: Date
    public let correlationID: UUID?
    public let category: String
    public let redactedReason: String
    public let outcome: String
    public let errorCode: String?
}

/// Conservative informational policy. No policy can authorize a system mutation.
public enum QuotaRisk: String, Codable, Sendable { case unknown, normal, warning, high, critical }
public enum QuotaEvaluator {
    public static func assess(profile: QuotaProfile, received: UInt64, sent: UInt64,
                              quality: SampleQuality) -> QuotaRisk {
        guard profile.schemaVersion == 1, profile.policyVerified,
              profile.scope != .unknown, quality == .measured || quality == .estimated,
              profile.receiveLimit > 0, profile.sendLimit > 0, profile.totalLimit > 0 else { return .unknown }
        let ratio = max(Double(received) / Double(profile.receiveLimit),
                        max(Double(sent) / Double(profile.sendLimit),
                            (Double(received) + Double(sent)) / Double(profile.totalLimit)))
        if ratio >= 0.95 { return .critical }
        if ratio >= 0.85 { return .high }
        if ratio >= 0.70 { return .warning }
        return .normal
    }
}
