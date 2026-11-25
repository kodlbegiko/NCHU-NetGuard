import Foundation

public struct TrafficRateSample: Equatable, Sendable {
    public let seconds: Double
    public let received: UInt64
    public let sent: UInt64
    public init(seconds: Double, received: UInt64, sent: UInt64) {
        self.seconds = seconds
        self.received = received
        self.sent = sent
    }
}

public enum LimitingBudget: String, Equatable, Sendable {
    case download, upload, total
}

public struct QuotaForecast: Equatable, Sendable {
    public let earliestSeconds: Double
    public let latestSeconds: Double
    public let limitingBudget: LimitingBudget
}

/// Conditional rate scenario, not a statistical confidence interval or a
/// promise of provider quota. Uses only continuous, same-scope samples.
public struct PredictionEngine: Sendable {
    private var samples: [TrafficRateSample] = []
    public init() {}
    public mutating func reset() { samples.removeAll(keepingCapacity: true) }

    public mutating func append(_ sample: TrafficRateSample) {
        guard sample.seconds.isFinite, (0.25...5).contains(sample.seconds) else {
            reset()
            return
        }
        samples.append(sample)
        if samples.count > 180 { samples.removeFirst(samples.count - 180) }
    }

    public func forecast(receiveRemaining: UInt64, sendRemaining: UInt64,
                         totalRemaining: UInt64) -> QuotaForecast? {
        guard samples.count >= 30, samples.reduce(0, { $0 + $1.seconds }) >= 30
        else { return nil }
        let budgets: [(LimitingBudget, UInt64, [Double])] = [
            (.download, receiveRemaining, samples.map { Double($0.received) / $0.seconds }),
            (.upload, sendRemaining, samples.map { Double($0.sent) / $0.seconds }),
            (.total, totalRemaining, samples.map { (Double($0.received) + Double($0.sent)) / $0.seconds })
        ]
        var estimates: [QuotaForecast] = []
        for (kind, remaining, rates) in budgets {
            if remaining == 0 {
                estimates.append(QuotaForecast(earliestSeconds: 0, latestSeconds: 0, limitingBudget: kind))
                continue
            }
            let sorted = rates.sorted()
            let low = sorted[Int(Double(sorted.count - 1) * 0.25)]
            let high = sorted[Int(Double(sorted.count - 1) * 0.75)]
            // Idle, bursty or insufficiently sustained traffic has no useful ETA.
            guard low >= 1024, high <= low * 4 else { continue }
            let earliest = Double(remaining) / high
            let latest = Double(remaining) / low
            guard earliest.isFinite, latest.isFinite, latest <= 24 * 3600 else { continue }
            estimates.append(QuotaForecast(earliestSeconds: earliest, latestSeconds: latest, limitingBudget: kind))
        }
        return estimates.min { $0.earliestSeconds < $1.earliestSeconds }
    }
}
