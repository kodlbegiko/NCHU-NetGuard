import Foundation

public struct ObservedInterfaceRate: Equatable, Sendable {
    public let download: Double
    public let upload: Double
    public init?(download: Double, upload: Double) {
        guard download.isFinite, upload.isFinite, download >= 0, upload >= 0 else { return nil }
        self.download = download; self.upload = upload
    }
}

public struct ObservedInterfaceRow: Equatable, Sendable, Identifiable {
    public let name: String
    public let scope: NetworkScope
    public let isDefault: Bool
    public let rate: ObservedInterfaceRate?
    public var id: String { name }
    public var scopeLabel: String {
        switch scope {
        case .dorm: return "宿網（估計）"
        case .campusWifi: return "校園 Wi-Fi（估計）"
        case .external: return "外部網路（估計）"
        case .unknown: return "未確認"
        }
    }
}
public struct ProcessSampleRow: Equatable, Sendable, Identifiable {
    public let name: String
    public let bytes: UInt64
    public var id: String { name }
    public init(name: String, bytes: UInt64) { self.name = name; self.bytes = bytes }
}
public struct ManagementSnapshot: Equatable, Sendable {
    public let interfaces: [ObservedInterfaceRow]
    public let processes: [ProcessSampleRow]
    public let processStatus: String
    public let sessionUsage: ProcessUsageReport?
    public let agentUsage: ProcessUsageReport?
    public let processBackgroundEnabled: Bool
    public let processObservationStatus: String
    public let connectionStatus: String
    public let latencyStatus: String
    public let tunnelStatus: String
    public let echoStatus: String
    public let dnsStatus: String
    public let findings: [DiagnosticFinding]
    public let providerStatus: String
    public let focusEnabled: Bool

    public init(scopes: [String: NetworkScope], defaultInterface: String,
                connectionKnown: Bool, latencyStatus: String,
                processRows: [ProcessSampleRow], processAge: TimeInterval?,
                focusEnabled: Bool, diagnosticInput: DiagnosticInput, providerStatus: String,
                rates: [String: ObservedInterfaceRate] = [:], tunnelCandidates: [String] = [],
                sessionUsage: ProcessUsageReport? = nil,
                echoStatus: String = "ICMP 尚未量測", dnsStatus: String = "DNS 尚未量測",
                agentUsage: ProcessUsageReport? = nil,
                processBackgroundEnabled: Bool = false, processObservationStatus: String = "僅開啟面板時觀測") {
        self.interfaces = scopes.keys.sorted().map {
            ObservedInterfaceRow(name: $0, scope: scopes[$0] ?? .unknown,
                                 isDefault: connectionKnown && $0 == defaultInterface, rate: rates[$0])
        }
        self.connectionStatus = connectionKnown ? "已辨識預設 IPv4 路由；不代表網際網路可用" : "連線尚未確認"
        self.latencyStatus = latencyStatus
        self.echoStatus = echoStatus
        self.dnsStatus = dnsStatus
        self.tunnelStatus = TunnelEvidence.description(defaultInterface: connectionKnown ? defaultInterface : "", candidates: tunnelCandidates)
        self.focusEnabled = focusEnabled
        self.sessionUsage = sessionUsage
        self.agentUsage = agentUsage
        self.processBackgroundEnabled = processBackgroundEnabled
        self.processObservationStatus = processObservationStatus
        let fresh = processAge.map { $0.isFinite && $0 >= 0 && $0 <= 30 } ?? false
        if focusEnabled {
            processes = []
            processStatus = "重要工作模式：暫停額外採樣"
        } else if fresh {
            var seen = Set<String>()
            processes = Array(processRows.sorted {
                $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes
            }.filter { seen.insert($0.name).inserted }.prefix(20))
            processStatus = "近期程序累計快照；非今日或個別網卡用量"
        } else {
            processes = []
            processStatus = "尚無近期採樣"
        }
        self.findings = DiagnosticsEngine.findings(diagnosticInput)
        self.providerStatus = providerStatus
    }
}


public enum ProcessSampleOrdering: Int, Sendable {
    case descendingBytes = 0, ascendingBytes = 1, name = 2
}

public enum ProcessSamplePresentation {
    /// Filter only the already-observed snapshot; never suggest a full process inventory.
    public static func visible(_ rows: [ProcessSampleRow], query: String, order: ProcessSampleOrdering) -> [ProcessSampleRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) }.sorted {
            switch order {
            case .descendingBytes:
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            case .ascendingBytes:
                if $0.bytes != $1.bytes { return $0.bytes < $1.bytes }
            case .name: break
            }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.name < $1.name : comparison == .orderedAscending
        }
    }
}
