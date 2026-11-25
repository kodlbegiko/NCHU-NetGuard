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
