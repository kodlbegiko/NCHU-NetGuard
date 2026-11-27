import Foundation

public struct AutomationSnapshot: Equatable, Sendable {
    public let alertsEnabled: Bool
    public let focusEnabled: Bool
    public let quotaTier: LocalQuotaTier?
    public let dormAttempt: LocalQuotaTier
    public let wifiAttempt: LocalQuotaTier
    public let ledgerStatus: String
    public let monitoringStatus: String
    public let rules: ObservationRuleSet?
    public let rulePreview: ObservationRulePreview?
    public let ruleStorageStatus: String

    public init(alertsEnabled: Bool, focusEnabled: Bool, sleeping: Bool,
                assessment: LocalQuotaAssessment?, ledger: QuotaAlertLedger,
                day: String, ledgerStatus: String,
                rules: ObservationRuleSet? = nil, rulePreview: ObservationRulePreview? = nil,
                ruleStorageStatus: String = "尚未讀取規則") {
        self.alertsEnabled = alertsEnabled
        self.focusEnabled = focusEnabled
        self.quotaTier = sleeping ? nil : assessment?.tier
        self.dormAttempt = ledger.recordedTier(day: day, scope: .dorm)
        self.wifiAttempt = ledger.recordedTier(day: day, scope: .campusWifi)
        self.ledgerStatus = ledgerStatus
        self.rules = rules
        self.rulePreview = rulePreview
        self.ruleStorageStatus = ruleStorageStatus
        self.monitoringStatus = sleeping ? "系統休眠，暫停採樣" :
            focusEnabled ? "持續監控，暫停額外探測" : "一般監控"
    }

    public static func tierLabel(_ tier: LocalQuotaTier?) -> String {
        guard let tier else { return "配額未確認" }
        switch tier {
        case .normal: return "未達提醒門檻"
        case .warning: return "70% 用量提醒"
        case .high: return "85% 高用量"
        case .critical: return "95% 極高用量"
        }
    }
    public static func attemptLabel(_ tier: LocalQuotaTier) -> String {
        tier == .normal ? "尚無提醒嘗試" : tierLabel(tier)
    }
}
