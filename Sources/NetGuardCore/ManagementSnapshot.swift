import Foundation

public struct ObservedInterfaceRow: Equatable, Sendable, Identifiable {
    public let name: String
    public let scope: NetworkScope
    public let isDefault: Bool
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
    public let connectionStatus: String
    public let latencyStatus: String
    public let findings: [DiagnosticFinding]
    public let providerStatus: String
    public let focusEnabled: Bool

    public init(scopes: [String: NetworkScope], defaultInterface: String,
                connectionKnown: Bool, latencyStatus: String,
                processRows: [ProcessSampleRow], processAge: TimeInterval?,
                focusEnabled: Bool, diagnosticInput: DiagnosticInput, providerStatus: String) {
        self.interfaces = scopes.keys.sorted().map {
            ObservedInterfaceRow(name: $0, scope: scopes[$0] ?? .unknown,
                                 isDefault: connectionKnown && $0 == defaultInterface)
        }
        self.connectionStatus = connectionKnown ? "已辨識預設 IPv4 路由；不代表網際網路可用" : "連線尚未確認"
        self.latencyStatus = latencyStatus
        self.focusEnabled = focusEnabled
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
