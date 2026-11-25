import Foundation

public enum NetworkQualityState: String, Equatable, Sendable {
    case unknown, responsive, elevatedLatency, highLatency
}

public struct NetworkQualityWindow: Sendable {
    private var values: [(uptime: TimeInterval, latency: Double)] = []
    public init() {}
    public mutating func reset() { values.removeAll() }
    public mutating func ingest(latency: Double?, uptime: TimeInterval) {
        guard let latency, latency.isFinite, latency >= 0, uptime.isFinite,
              values.last.map({ uptime > $0.uptime }) ?? true else { reset(); return }
        values.append((uptime, latency))
        if values.count > 5 { values.removeFirst() }
    }
    public func state(at uptime: TimeInterval) -> NetworkQualityState {
        guard values.count >= 3, let first = values.first, let last = values.last,
              uptime.isFinite, uptime >= last.uptime, uptime - last.uptime <= 120,
              last.uptime - first.uptime <= 360 else { return .unknown }
        let sorted = values.map(\.latency).sorted()
        let median = sorted[sorted.count / 2]
        if median >= 150 { return .highLatency }
        if median >= 60 { return .elevatedLatency }
        return .responsive
    }
}

public extension NetworkQualityState {
    var description: String {
        switch self {
        case .unknown: return "延遲樣本不足或已過期"
        case .responsive: return "近期探測延遲較低"
        case .elevatedLatency: return "近期探測延遲偏高"
        case .highLatency: return "近期探測延遲較高"
        }
    }
}
