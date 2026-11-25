import Foundation

public enum NetworkQualityState: String, Equatable, Sendable {
    case unknown, responsive, elevatedLatency, highLatency
}

public struct LatencySummary: Equatable, Sendable {
    public let sampleCount: Int
    public let medianMilliseconds: Double
    /// Mean absolute change between consecutive probe results. Not packet jitter.
    public let meanChangeMilliseconds: Double
}

public struct NetworkQualityWindow: Sendable {
    private var values: [(uptime: TimeInterval, latency: Double)] = []
    public init() {}
    public mutating func reset() { values.removeAll() }
    public mutating func ingest(latency: Double?, uptime: TimeInterval) {
        guard let latency, latency.isFinite, latency >= 0, uptime.isFinite, uptime >= 0,
              values.last.map({ uptime > $0.uptime }) ?? true else { reset(); return }
        values.append((uptime, latency))
        if values.count > 5 { values.removeFirst() }
    }
    public func summary(at uptime: TimeInterval) -> LatencySummary? {
        guard values.count >= 3, let first = values.first, let last = values.last,
              uptime.isFinite, uptime >= last.uptime, uptime - last.uptime <= 120,
              last.uptime - first.uptime <= 360 else { return nil }
        let rates = values.map(\.latency)
        let sorted = rates.sorted()
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? sorted[mid - 1] / 2 + sorted[mid] / 2 : sorted[mid]
        let change = zip(rates, rates.dropFirst()).reduce(0.0) { sum, pair in
            sum + abs(pair.0 - pair.1) / Double(rates.count - 1)
        }
        guard median.isFinite, change.isFinite else { return nil }
        return LatencySummary(sampleCount: rates.count, medianMilliseconds: median, meanChangeMilliseconds: change)
    }

    public func state(at uptime: TimeInterval) -> NetworkQualityState {
        guard let median = summary(at: uptime)?.medianMilliseconds else { return .unknown }
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


/// Bounded, session-only, active-interface rate history. Missing measurements,
/// identity changes, and invalid clocks break continuity rather than implying zero.
public struct ThroughputPoint: Equatable, Sendable {
    public let uptime: TimeInterval
    public let downloadBytesPerSecond: Double
    public let uploadBytesPerSecond: Double
}

public struct ThroughputWindow: Sendable {
    private var identity: String?
    private var points: [ThroughputPoint] = []
    public init() {}
    public mutating func reset() {
        identity = nil
        points.removeAll(keepingCapacity: true)
    }
    public mutating func ingest(identity: String, uptime: TimeInterval,
                                download: Double?, upload: Double?) {
        guard !identity.isEmpty, uptime.isFinite, uptime >= 0,
              let download, let upload, download.isFinite, upload.isFinite,
              download >= 0, upload >= 0 else { reset(); return }
        if self.identity != identity ||
            points.last.map({ uptime <= $0.uptime || uptime - $0.uptime > 5 }) == true {
            reset()
        }
        self.identity = identity
        points.append(.init(uptime: uptime, downloadBytesPerSecond: download, uploadBytesPerSecond: upload))
        points.removeAll { uptime - $0.uptime > 60 }
        if points.count > 120 { points.removeFirst(points.count - 120) }
    }
    public func recent(at uptime: TimeInterval) -> [ThroughputPoint] {
        guard let last = points.last, uptime.isFinite,
              uptime >= last.uptime, uptime - last.uptime <= 5 else { return [] }
        return points.filter { uptime - $0.uptime <= 60 }
    }
}
