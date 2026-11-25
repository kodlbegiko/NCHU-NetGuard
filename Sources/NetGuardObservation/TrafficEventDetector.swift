import Foundation

public enum TrafficEventKind: String, Codable, Sendable {
    case sustainedHigh, surge, observationGap
    public var title: String {
        switch self {
        case .sustainedHigh: return "持續高流量"
        case .surge: return "流量突增"
        case .observationGap: return "觀測中斷"
        }
    }
}

/// Validated local descriptive rules. Integer configuration avoids ambiguous
/// units, non-finite inputs and locale-dependent persisted values.
public struct TrafficEventRules: Codable, Equatable, Sendable {
    public let highMiB: Int
    public let highSeconds: Int
    public let surgeMiB: Int
    public let surgeMultiplier: Int

    public static let standard = TrafficEventRules(highMiB: 5, highSeconds: 10, surgeMiB: 1, surgeMultiplier: 4)!
    public init?(highMiB: Int, highSeconds: Int, surgeMiB: Int, surgeMultiplier: Int) {
        guard (1...1024).contains(highMiB), (5...120).contains(highSeconds),
              (1...1024).contains(surgeMiB), (2...20).contains(surgeMultiplier) else { return nil }
        self.highMiB = highMiB; self.highSeconds = highSeconds
        self.surgeMiB = surgeMiB; self.surgeMultiplier = surgeMultiplier
    }
    public static func validatedDecode(_ data: Data) -> Self? {
        guard data.count <= 4096, let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return Self(highMiB: decoded.highMiB, highSeconds: decoded.highSeconds,
                    surgeMiB: decoded.surgeMiB, surgeMultiplier: decoded.surgeMultiplier)
    }
}

public struct TrafficObservationEvent: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let kind: TrafficEventKind
    public let bytesPerSecond: Double?
    public let referenceBytesPerSecond: Double?
    public let duration: TimeInterval?
}

/// Descriptive local heuristics, not security or billing conclusions.
/// Retains at most 100 events for the current process lifetime.
public struct TrafficEventDetector: Sendable {
    private var identity: String?
    private var last: TimeInterval?
    private var baseline: [(TimeInterval, Double)] = []
    private var highSince: TimeInterval?
    private var highReported = false
    private var lastSurge: TimeInterval?
    private var surgeActive = false
    private var events: [TrafficObservationEvent] = []
    public private(set) var rules = TrafficEventRules.standard
    public init() {}

    public mutating func configure(_ rules: TrafficEventRules) {
        guard let checked = TrafficEventRules(highMiB: rules.highMiB, highSeconds: rules.highSeconds, surgeMiB: rules.surgeMiB, surgeMultiplier: rules.surgeMultiplier), checked != self.rules else { return }
        self.rules = checked
        resetContinuity()
    }

    private mutating func append(_ kind: TrafficEventKind, date: Date,
                                 rate: Double? = nil, reference: Double? = nil,
                                 duration: TimeInterval? = nil) {
        guard date.timeIntervalSince1970.isFinite else { return }
        events.append(.init(id: UUID(), date: date, kind: kind,
            bytesPerSecond: rate, referenceBytesPerSecond: reference, duration: duration))
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }

    /// Deliberate boundaries (sleep, route change) discard the baseline.
    /// They do not claim missing traffic or produce a high-flow event.
    public mutating func resetContinuity() {
        identity = nil; last = nil; baseline.removeAll()
        highSince = nil; highReported = false; lastSurge = nil; surgeActive = false
    }
    public mutating func clear() {
        events.removeAll()
        resetContinuity()
    }
    public func recent() -> [TrafficObservationEvent] { Array(events.reversed()) }

    public mutating func ingest(identity: String?, uptime: TimeInterval, date: Date,
                                download: Double?, upload: Double?) {
        guard uptime.isFinite, uptime >= 0, date.timeIntervalSince1970.isFinite else {
            resetContinuity(); return
        }
        guard let identity, !identity.isEmpty, let download, let upload,
              download.isFinite, upload.isFinite, download >= 0, upload >= 0,
              (download + upload).isFinite else {
            if last != nil { append(.observationGap, date: date) }
            resetContinuity()
            return
        }
        if self.identity != identity { resetContinuity() }
        if let last, uptime <= last || uptime - last > 5 {
            append(.observationGap, date: date)
            resetContinuity()
        }
        self.identity = identity
        last = uptime
        let rate = download + upload
        baseline.removeAll { uptime - $0.0 > 60 }
        // Use only preceding measurements, not the current surge.
        if baseline.count >= 20, let first = baseline.first, uptime - first.0 >= 20 {
            let sorted = baseline.map { $0.1 }.sorted()
            let median = sorted[sorted.count / 2]
            let threshold = max(Double(rules.surgeMiB) * 1_048_576, median * Double(rules.surgeMultiplier))
            let above = rate >= threshold && rate > median
            if above && !surgeActive &&
                (lastSurge.map { uptime - $0 >= 60 } ?? true) {
                append(.surge, date: date, rate: rate, reference: median)
                lastSurge = uptime
            }
            surgeActive = above
        }
        if rate >= Double(rules.highMiB) * 1_048_576 {
            if highSince == nil { highSince = uptime }
            if let start = highSince, uptime - start >= Double(rules.highSeconds), !highReported {
                append(.sustainedHigh, date: date, rate: rate, duration: uptime - start)
                highReported = true
            }
        } else {
            highSince = nil; highReported = false
        }
        baseline.append((uptime, rate))
        if baseline.count > 120 { baseline.removeFirst(baseline.count - 120) }
    }
}
