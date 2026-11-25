import Foundation

public enum LocalQuotaTier: Int, Codable, Comparable, Sendable {
    case normal = 0, warning = 1, high = 2, critical = 3
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LocalQuotaAssessment: Equatable, Sendable {
    public let tier: LocalQuotaTier
    public let limitingBudget: LimitingBudget
    public let usageRatio: Double
}

/// Informational only. Legacy configured limits are not asserted as verified
/// campus policy; callers must label every result as a local estimate.
public enum LocalQuotaPolicy {
    public static func assess(received: UInt64, sent: UInt64, receiveLimit: UInt64,
                              sendLimit: UInt64, totalLimit: UInt64) -> LocalQuotaAssessment? {
        guard receiveLimit > 0, sendLimit > 0, totalLimit > 0 else { return nil }
        let values: [(LimitingBudget, Double)] = [
            (.download, Double(received) / Double(receiveLimit)),
            (.upload, Double(sent) / Double(sendLimit)),
            (.total, (Double(received) + Double(sent)) / Double(totalLimit))
        ]
        guard let maximum = values.max(by: { $0.1 < $1.1 }) else { return nil }
        let tier: LocalQuotaTier = maximum.1 >= 0.95 ? .critical :
            maximum.1 >= 0.85 ? .high : maximum.1 >= 0.70 ? .warning : .normal
        return LocalQuotaAssessment(tier: tier, limitingBudget: maximum.0, usageRatio: maximum.1)
    }
}

public struct QuotaAlertLedger: Codable, Equatable, Sendable {
    private var day: String?
    private var notified: [NetworkScope: LocalQuotaTier] = [:]
    public init() {}

    /// Explicit persistence format: caller stores the day alongside the tiers.
    /// These are attempts, not proof of notification delivery.
    public func recordedTier(day: String, scope: NetworkScope) -> LocalQuotaTier {
        self.day == day ? (notified[scope] ?? .normal) : .normal
    }

    public func persistedTiers(day: String) -> [String: Int] {
        guard self.day == day else { return [:] }
        return Dictionary(uniqueKeysWithValues: notified.map { ($0.key.rawValue, $0.value.rawValue) })
    }

    public mutating func restore(day: String, tiers: [String: Int]) throws {
        var restored: [NetworkScope: LocalQuotaTier] = [:]
        for (key, value) in tiers {
            guard let scope = NetworkScope(rawValue: key),
                  scope == .dorm || scope == .campusWifi,
                  let tier = LocalQuotaTier(rawValue: value), tier > .normal
            else { throw ContractError.invalidField("alertLedger") }
            restored[scope] = tier
        }
        self.day = day
        notified = restored
    }

    /// At most one notification per increasing tier, per scope/day.
    /// Disabling alerts does not consume a notification tier.
    public mutating func shouldNotify(day: String, scope: NetworkScope,
                                      tier: LocalQuotaTier, enabled: Bool) -> Bool {
        if self.day != day { self.day = day; notified = [:] }
        guard enabled, scope == .dorm || scope == .campusWifi,
              tier > .normal, tier > (notified[scope] ?? .normal) else { return false }
        notified[scope] = tier
        return true
    }
}


/// A user-defined daily total budget for a local accounting category, not
/// a verified ISP balance or an individual SSID/mobile subscription.
public struct PersonalDailyBudget: Codable, Equatable, Sendable {
    public let scope: NetworkScope
    public let limitBytes: UInt64
    public init(scope: NetworkScope, decimalGigabytes: UInt64) throws {
        guard scope != .unknown, (1...10_000).contains(decimalGigabytes) else {
            throw ContractError.invalidField("personalBudget")
        }
        self.scope = scope
        self.limitBytes = decimalGigabytes * 1_000_000_000
    }
    public var decimalGigabytes: UInt64 { limitBytes / 1_000_000_000 }
    public func validate() throws {
        guard scope != .unknown, limitBytes % 1_000_000_000 == 0,
              (1...10_000).contains(decimalGigabytes) else {
            throw ContractError.invalidField("personalBudget")
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw ContractError.invalidField("personalBudget") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    public func evaluate(received: UInt64, sent: UInt64, observed: Bool) -> PersonalBudgetReading? {
        guard observed, (try? validate()) != nil else { return nil }
        let (used, overflow) = received.addingReportingOverflow(sent)
        guard !overflow else { return nil }
        return .init(used: used, limit: limitBytes)
    }
}

public struct PersonalBudgetReading: Equatable, Sendable {
    public let used: UInt64
    public let limit: UInt64
    public var remaining: UInt64 { used >= limit ? 0 : limit - used }
    public var fraction: Double { min(1, Double(used) / Double(limit)) }
}

public enum RateDisplayUnit: String, CaseIterable, Sendable {
    case binaryBytes, decimalBits
    public func format(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "未量測" }
        switch self {
        case .binaryBytes:
            if bytesPerSecond >= 1_048_576 { return String(format: "%.1f MiB/s", bytesPerSecond / 1_048_576) }
            if bytesPerSecond >= 1024 { return String(format: "%.0f KiB/s", bytesPerSecond / 1024) }
            return String(format: "%.0f B/s", bytesPerSecond)
        case .decimalBits:
            let bits = bytesPerSecond * 8
            guard bits.isFinite else { return "未量測" }
            if bits >= 1_000_000 { return String(format: "%.1f Mbps", bits / 1_000_000) }
            if bits >= 1000 { return String(format: "%.0f kbps", bits / 1000) }
            return String(format: "%.0f bps", bits)
        }
    }
}
