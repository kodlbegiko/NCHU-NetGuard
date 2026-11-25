import Foundation

public struct DiagnosticInput: Equatable, Sendable {
    public let connected: Bool
    public let scope: NetworkScope
    public let persistenceHealthy: Bool
    public let sampleGapCount: Int
    public let providerFresh: Bool
    public init(connected: Bool, scope: NetworkScope, persistenceHealthy: Bool,
                sampleGapCount: Int, providerFresh: Bool) {
        self.connected = connected
        self.scope = scope
        self.persistenceHealthy = persistenceHealthy
        self.sampleGapCount = sampleGapCount
        self.providerFresh = providerFresh
    }
}
public enum DiagnosticFinding: String, Codable, Sendable {
    case storageIssue, connectionUnknown, scopeUnknown, incompleteSamples, providerUnknown, observing
    public var summary: String {
        switch self {
        case .storageIssue: return "本機紀錄需檢查；原始資料不會被強制覆寫。"
        case .connectionUnknown: return "連線尚未確認；請檢查 macOS 網路設定。"
        case .scopeUnknown: return "網路歸屬未確認，暫不判定剩餘配額。"
        case .incompleteSamples: return "部分流量未能完整採樣，目前數值僅供估計。"
        case .providerUnknown: return "校方資料尚未確認；可開啟官方頁面核對。"
        case .observing: return "本機監控中；不代表校方配額或網路安全已確認。"
        }
    }
}
public enum DiagnosticsEngine {
    /// Ordered by actionable urgency; no mutations, no claims of safety.
    public static func findings(_ input: DiagnosticInput) -> [DiagnosticFinding] {
        var result: [DiagnosticFinding] = []
        if !input.persistenceHealthy { result.append(.storageIssue) }
        if !input.connected { result.append(.connectionUnknown) }
        if input.scope == .unknown { result.append(.scopeUnknown) }
        if input.sampleGapCount > 0 { result.append(.incompleteSamples) }
        if input.scope == .dorm && !input.providerFresh { result.append(.providerUnknown) }
        return result.isEmpty ? [.observing] : result
    }
}
