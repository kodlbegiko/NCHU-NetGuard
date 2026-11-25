import Foundation

/// UI-independent projection: unknown is not zero; configured quota is not
/// authoritative provider balance. Values are bytes, displayed by the host.
public struct QuickPanelBudget: Equatable, Sendable {
    public let used: UInt64
    public let limit: UInt64
    public var remaining: UInt64 { used >= limit ? 0 : limit - used }
    public var fraction: Double { min(1, Double(used) / Double(limit)) }
    public init?(used: Double, limit: Double) {
        guard let used = UInt64(exactly: used), let limit = UInt64(exactly: limit), limit > 0 else { return nil }
        self.used = used
        self.limit = limit
    }
}

public struct QuickPanelState: Equatable, Sendable {
    public let networkName: String
    public let download: QuickPanelBudget?
    public let upload: QuickPanelBudget?
    public let speedText: String
    public let throughput: [ThroughputPoint]
    public let diagnostic: String
    public let forecast: String
    public let provider: String
    public let focusEnabled: Bool
    public let alertsEnabled: Bool

    public init(networkName: String, connectionKnown: Bool, scope: NetworkScope,
                received: Double, sent: Double, receiveLimit: Double, sendLimit: Double,
                speedText: String, diagnostic: String, forecast: String, provider: String,
                focusEnabled: Bool, alertsEnabled: Bool, throughput: [ThroughputPoint] = []) {
        self.networkName = connectionKnown ? networkName : "網路尚未確認"
        let eligible = connectionKnown && (scope == .dorm || scope == .campusWifi)
        self.download = eligible ? QuickPanelBudget(used: received, limit: receiveLimit) : nil
        self.upload = eligible ? QuickPanelBudget(used: sent, limit: sendLimit) : nil
        self.speedText = connectionKnown ? speedText : "未量測"
        self.throughput = connectionKnown ? throughput : []
        self.diagnostic = diagnostic
        self.forecast = eligible ? forecast : "配額未確認"
        self.provider = provider
        self.focusEnabled = focusEnabled
        self.alertsEnabled = alertsEnabled
    }

    public static let initial = QuickPanelState(networkName: "", connectionKnown: false,
        scope: .unknown, received: 0, sent: 0, receiveLimit: 0, sendLimit: 0,
        speedText: "未量測", diagnostic: "正在讀取本機狀態", forecast: "",
        provider: "校方資料尚未確認", focusEnabled: false, alertsEnabled: false)
}
