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
        // A caller-confirmed exhausted local budget needs no rate estimate.
        if receiveRemaining == 0 { return .init(earliestSeconds: 0, latestSeconds: 0, limitingBudget: .download) }
        if sendRemaining == 0 { return .init(earliestSeconds: 0, latestSeconds: 0, limitingBudget: .upload) }
        if totalRemaining == 0 { return .init(earliestSeconds: 0, latestSeconds: 0, limitingBudget: .total) }
        guard samples.count >= 30, samples.reduce(0, { $0 + $1.seconds }) >= 30
        else { return nil }
        let budgets: [(LimitingBudget, UInt64, [Double])] = [
            (.download, receiveRemaining, samples.map { Double($0.received) / $0.seconds }),
            (.upload, sendRemaining, samples.map { Double($0.sent) / $0.seconds }),
            (.total, totalRemaining, samples.map { (Double($0.received) + Double($0.sent)) / $0.seconds })
        ]
        var estimates: [QuotaForecast] = []
        for (kind, remaining, rates) in budgets {
            let weighted = zip(rates, samples.map(\.seconds)).map { (rate: $0.0, duration: $0.1) }
            guard let low = Self.percentile(weighted, fraction: 0.25),
                  let high = Self.percentile(weighted, fraction: 0.75) else { continue }
            // Idle or variable traffic has no useful ETA. Weight by elapsed
            // time: a 0.25-second spike is not five seconds of evidence.
            guard low >= 1024, high <= low * 4 else { continue }
            // Compare consecutive halves of the observation window. A change
            // in median speed by more than 2x is a heuristic drift signal,
            // not a formal statistical test. Fail closed rather than extrapolate.
            let split = Self.splitByDuration(weighted)
            guard let oldMedian = Self.percentile(split.0, fraction: 0.5),
                  let recentMedian = Self.percentile(split.1, fraction: 0.5),
                  oldMedian >= 1024, recentMedian >= 1024,
                  max(oldMedian, recentMedian) <= min(oldMedian, recentMedian) * 2
            else { continue }
            let earliest = Double(remaining) / high
            let latest = Double(remaining) / low
            guard earliest.isFinite, latest.isFinite, latest <= 24 * 3600 else { continue }
            estimates.append(QuotaForecast(earliestSeconds: earliest, latestSeconds: latest, limitingBudget: kind))
        }
        return estimates.min { $0.earliestSeconds < $1.earliestSeconds }
    }

    private typealias WeightedRate = (rate: Double, duration: Double)
    private static func percentile(_ values: [WeightedRate], fraction: Double) -> Double? {
        let total = values.reduce(0.0) { $0 + $1.duration }
        guard total.isFinite, total > 0 else { return nil }
        let target = total * fraction
        var cumulative = 0.0
        for item in values.sorted(by: { $0.rate < $1.rate }) {
            cumulative += item.duration
            if cumulative >= target { return item.rate }
        }
        return nil
    }
    private static func splitByDuration(_ values: [WeightedRate]) -> ([WeightedRate], [WeightedRate]) {
        let midpoint = values.reduce(0.0) { $0 + $1.duration } / 2
        var before: [WeightedRate] = [], after: [WeightedRate] = [], elapsed = 0.0
        for value in values {
            let firstDuration = min(value.duration, max(0, midpoint - elapsed))
            if firstDuration > 0 { before.append((value.rate, firstDuration)) }
            let rest = value.duration - firstDuration
            if rest > 0 { after.append((value.rate, rest)) }
            elapsed += value.duration
        }
        return (before, after)
    }
}

/// Offline walk-forward evaluation of conditional rate scenarios. The caller
/// must supply contiguous samples from one scope and measurement boundary.
/// No data is fetched and no prediction is made using the held-out interval.
public struct QuotaBacktestResult: Equatable, Sendable {
    public let origins: Int
    public let predicted: Int
    public let resolved: Int
    public let consistent: Int
    public let censored: Int
    public var intervalConsistency: Double? { resolved > 0 ? Double(consistent) / Double(resolved) : nil }
}
public enum QuotaBacktest {
    public static func evaluate(samples: [TrafficRateSample], trainingCount: Int = 30,
                                stride: Int = 30, receiveBudget: UInt64,
                                sendBudget: UInt64, totalBudget: UInt64) -> QuotaBacktestResult? {
        guard (30...180).contains(trainingCount), (1...180).contains(stride),
              samples.count > trainingCount, samples.count <= 4096,
              receiveBudget > 0, sendBudget > 0, totalBudget > 0,
              samples.allSatisfy({ $0.seconds.isFinite && (0.25...5).contains($0.seconds) })
        else { return nil }
        var origins = 0, predicted = 0, resolved = 0, consistent = 0, censored = 0
        for index in Swift.stride(from: trainingCount, to: samples.count, by: stride) {
            origins += 1
            var engine = PredictionEngine()
            for row in samples[(index - trainingCount)..<index] { engine.append(row) }
            guard let forecast = engine.forecast(receiveRemaining: receiveBudget,
                                                 sendRemaining: sendBudget, totalRemaining: totalBudget)
            else { continue }
            predicted += 1
            var rx = receiveBudget, tx = sendBudget, total = totalBudget
            var elapsed = 0.0, found = false
            for sample in samples[index...] {
                let before = elapsed
                elapsed += sample.seconds
                // Saturating subtraction avoids overflow even for extreme
                // integer counters. A crossing is only known within a sample.
                rx -= min(rx, sample.received)
                tx -= min(tx, sample.sent)
                total -= min(total, sample.received)
                total -= min(total, sample.sent)
                if rx == 0 || tx == 0 || total == 0 {
                    resolved += 1; found = true
                    let matchingDirection = (rx == 0 && forecast.limitingBudget == .download)
                        || (tx == 0 && forecast.limitingBudget == .upload)
                        || (total == 0 && forecast.limitingBudget == .total)
                    if matchingDirection && forecast.earliestSeconds <= elapsed && forecast.latestSeconds >= before {
                        consistent += 1
                    }
                    break
                }
            }
            if !found { censored += 1 }
        }
        return .init(origins: origins, predicted: predicted, resolved: resolved,
                     consistent: consistent, censored: censored)
    }
}


/// Present a conditional local-counter scenario without implying complete
/// daily coverage, provider billing, or a statistical confidence interval.
public enum LocalForecastPresentation {
    public static func describe(assessment: LocalQuotaAssessment?, forecast: QuotaForecast?,
                                hasGaps: Bool, hasUnattributedTraffic: Bool = false) -> (message: String, level: String) {
        guard let assessment, assessment.usageRatio.isFinite, assessment.usageRatio >= 0
        else { return ("配額未確認，暫不預測", "unknown") }
        func label(_ budget: LimitingBudget) -> String {
            switch budget {
            case .download: return "下載"
            case .upload: return "上傳"
            case .total: return "總量"
            }
        }
        let level = assessment.tier >= .high ? "danger" : (assessment.tier == .warning ? "warning" : "unknown")
        let coverage = (hasGaps ? "；未觀測流量不計入" : "") +
            (hasUnattributedTraffic ? "；未歸類流量不計入" : "")
        let status = "本機估計：\(label(assessment.limitingBudget))已用 \(Int(min(assessment.usageRatio * 100, 999)))%"
        guard let f = forecast, f.earliestSeconds.isFinite, f.latestSeconds.isFinite,
              f.earliestSeconds >= 0, f.earliestSeconds <= f.latestSeconds,
              f.latestSeconds <= 86_400
        else { return (status + coverage + "；暫無可靠速率推估", level) }
        if f.latestSeconds == 0 {
            return ("本機已觀測\(label(f.limitingBudget))達設定上限" + coverage + "；非校方結算", "danger")
        }
        let low = Int(floor(f.earliestSeconds / 60))
        let high = Int(ceil(f.latestSeconds / 60))
        let duration = high == 1 && low == 0 ? "不到 1 分鐘" : "約 \(low)–\(high) 分鐘"
        return ("若近期速率持續，本機\(label(f.limitingBudget))計數\(duration)達設定上限" + coverage + "；非校方結算", level)
    }
}
