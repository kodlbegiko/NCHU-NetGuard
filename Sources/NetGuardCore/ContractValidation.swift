import Foundation

public enum ContractError: Error, Equatable {
    case unsupportedVersion
    case oversizedDocument
    case invalidField(String)
}

/// Decode at trust boundaries, not merely as a Codable value. Validation is
/// structural; it is not consent, a verified network policy, or authorization.
public protocol ValidatedContract: Codable {
    var schemaVersion: Int { get }
    func validateFields() throws
}

public extension ValidatedContract {
    func validate() throws {
        guard schemaVersion == 1 else { throw ContractError.unsupportedVersion }
        try validateFields()
    }
    static func decodeValidated(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw ContractError.oversizedDocument }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
}

private func require(_ condition: Bool, _ field: String) throws {
    guard condition else { throw ContractError.invalidField(field) }
}

private func nonempty(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    value.utf8.count <= 4096 &&
    value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
}

private func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }

extension TrafficSnapshot: ValidatedContract {
    public func validateFields() throws {
        try require(finite(timestamp), "timestamp")
        try require(interfaces.count <= 256, "interfaces")
        try require(quality != .measured || !interfaces.isEmpty, "quality")
        try require(Set(interfaces.map(\.interfaceID)).count == interfaces.count, "interfaces")
        try require(interfaces.allSatisfy { nonempty($0.interfaceID) }, "interfaceID")
    }
}

extension NetworkSnapshot: ValidatedContract {
    public func validateFields() throws {
        try require(finite(observedAt), "observedAt")
        try require(interfaces.count <= 256, "interfaces")
        try require(Set(interfaces.map(\.serviceID)).count == interfaces.count, "serviceID")
        try require(interfaces.allSatisfy { nonempty($0.serviceID) && nonempty($0.name) }, "interfaces")
    }
}

extension QuotaProfile: ValidatedContract {
    public func validateFields() throws {
        try require(nonempty(providerID) && nonempty(policySource), "provider")
        try require(scope == .dorm || scope == .campusWifi, "scope")
        try require(receiveLimit > 0 && sendLimit > 0 && totalLimit > 0, "limits")
        try require(totalLimit >= max(receiveLimit, sendLimit), "totalLimit")
        try require(TimeZone(identifier: resetTimeZoneID) != nil, "resetTimeZoneID")
    }
}

extension PolicyDecision: ValidatedContract {
    public func validateFields() throws {
        try require(finite(expiresAt), "expiresAt")
        try require(nonempty(reason), "reason")
        try require(kind != .requestAuthorization || requiresAuthorization, "requiresAuthorization")
    }
}

extension NetworkAction: ValidatedContract {
    public func validateFields() throws {
        try require(nonempty(targetServiceID), "targetServiceID")
        try require(nonempty(preconditionDigest), "preconditionDigest")
        try require((1...60).contains(timeoutSeconds), "timeoutSeconds")
    }
}

extension RecoverySnapshot: ValidatedContract {
    public func validateFields() throws {
        try require(finite(observedAt), "observedAt")
        try require(!ownedConfiguration.isEmpty && ownedConfiguration.count <= 256 &&
                    ownedConfiguration.keys.allSatisfy(nonempty) &&
                    ownedConfiguration.values.allSatisfy { $0.utf8.count <= 4096 }, "ownedConfiguration")
        try require(nonempty(integrityDigest), "integrityDigest")
    }
}

extension ProtectedWorkflow: ValidatedContract {
    public func validateFields() throws {
        try require(finite(expiresAt), "expiresAt")
        try require(nonempty(processIdentity), "processIdentity")
    }
}

extension EventRecord: ValidatedContract {
    public func validateFields() throws {
        try require(finite(timestamp), "timestamp")
        try require(nonempty(category) && nonempty(redactedReason) && nonempty(outcome), "event")
        try require(errorCode.map(nonempty) ?? true, "errorCode")
    }
}

// Structural validation is deliberately independent of the current clock.
// Consumers must check expiry at use time; these helpers do not grant consent.
public extension PolicyDecision {
    func isCurrent(at now: Date) -> Bool {
        (try? validate()) != nil && finite(now) && now < expiresAt
    }
}
public extension ProtectedWorkflow {
    func isOptedIn(at now: Date) -> Bool {
        (try? validate()) != nil && optedIn && finite(now) && now < expiresAt
    }
}
