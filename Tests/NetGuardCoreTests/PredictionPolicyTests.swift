import XCTest
@testable import NetGuardCore

final class PredictionPolicyTests: XCTestCase {
    func testStableUploadCanBeLimitingBudget() throws {
        var engine = PredictionEngine()
        for _ in 0..<40 { engine.append(TrafficRateSample(seconds: 1, received: 1024, sent: 2048)) }
        let f = try XCTUnwrap(engine.forecast(receiveRemaining: 1_024_000, sendRemaining: 204_800, totalRemaining: 2_048_000))
        XCTAssertEqual(f.limitingBudget, .upload)
        XCTAssertEqual(f.earliestSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(f.latestSeconds, 100, accuracy: 0.001)
    }
    func testSparseIdleAndResetDoNotPredict() {
        var engine = PredictionEngine()
        for _ in 0..<29 { engine.append(TrafficRateSample(seconds: 1, received: 1024, sent: 0)) }
        XCTAssertNil(engine.forecast(receiveRemaining: 10000, sendRemaining: 10000, totalRemaining: 10000))
        engine.append(TrafficRateSample(seconds: 10, received: 1024, sent: 0))
        for _ in 0..<40 { engine.append(TrafficRateSample(seconds: 1, received: 0, sent: 0)) }
        XCTAssertNil(engine.forecast(receiveRemaining: 10000, sendRemaining: 10000, totalRemaining: 10000))
    }
    func testVariableRatesDeclineToPredict() {
        var engine = PredictionEngine()
        for i in 0..<40 {
            engine.append(TrafficRateSample(seconds: 1, received: i % 2 == 0 ? 1024 : 100_000, sent: 0))
        }
        XCTAssertNil(engine.forecast(receiveRemaining: 1000000, sendRemaining: 1000000, totalRemaining: 2000000))
    }
    func testDurationWeightingDoesNotExtrapolateShortSpikes() {
        var engine = PredictionEngine()
        for _ in 0..<20 { engine.append(.init(seconds: 5, received: 0, sent: 0)) }
        for _ in 0..<60 { engine.append(.init(seconds: 0.25, received: 100_000, sent: 0)) }
        XCTAssertNil(engine.forecast(receiveRemaining: 1_000_000, sendRemaining: 1_000_000, totalRemaining: 2_000_000))
    }
    func testRateRegimeShiftSuppressesForecast() {
        var engine = PredictionEngine()
        for _ in 0..<30 { engine.append(.init(seconds: 1, received: 1024, sent: 0)) }
        for _ in 0..<30 { engine.append(.init(seconds: 1, received: 3072, sent: 0)) }
        XCTAssertNil(engine.forecast(receiveRemaining: 1_000_000, sendRemaining: 1_000_000, totalRemaining: 2_000_000))
    }
    func testExhaustedBudgetDoesNotRequireRate() {
        let engine = PredictionEngine()
        let result = engine.forecast(receiveRemaining: 100, sendRemaining: 0, totalRemaining: 100)
        XCTAssertEqual(result?.limitingBudget, .upload)
        XCTAssertEqual(result?.latestSeconds, 0)
    }
    func testWalkForwardBacktestSeparatesResolvedAndCensored() throws {
        let samples = Array(repeating: TrafficRateSample(seconds: 1, received: 1024, sent: 2048), count: 100)
        let result = try XCTUnwrap(QuotaBacktest.evaluate(samples: samples, receiveBudget: 1_000_000,
            sendBudget: 20_480, totalBudget: 2_000_000))
        XCTAssertEqual(result.origins, 3)
        XCTAssertEqual(result.predicted, 3)
        XCTAssertEqual(result.resolved, 3)
        XCTAssertEqual(result.consistent, 3)
        XCTAssertEqual(result.intervalConsistency, 1)
        let censored = try XCTUnwrap(QuotaBacktest.evaluate(samples: samples, receiveBudget: 1_000_000,
            sendBudget: 40_960, totalBudget: 2_000_000))
        XCTAssertEqual(censored.resolved, 2)
        XCTAssertEqual(censored.censored, 1)
        XCTAssertNil(QuotaBacktest.evaluate(samples: samples + [.init(seconds: .nan, received: 0, sent: 0)],
            receiveBudget: 1_000_000, sendBudget: 40_960, totalBudget: 2_000_000))
    }
    func testLocalForecastExplicitlyLabelsGapsAndNeverClaimsBilling() throws {
        let assessment = try XCTUnwrap(LocalQuotaPolicy.assess(received: 80, sent: 10,
            receiveLimit: 100, sendLimit: 100, totalLimit: 200))
        let result = LocalForecastPresentation.describe(assessment: assessment,
            forecast: .init(earliestSeconds: 30, latestSeconds: 50, limitingBudget: .download), hasGaps: true)
        XCTAssertTrue(result.message.contains("不到 1 分鐘"))
        XCTAssertTrue(result.message.contains("未觀測流量不計入"))
        XCTAssertTrue(result.message.contains("非校方結算"))
        let unavailable = LocalForecastPresentation.describe(assessment: assessment,
            forecast: nil, hasGaps: true)
        XCTAssertTrue(unavailable.message.contains("暫無可靠速率推估"))
        XCTAssertTrue(unavailable.message.contains("未觀測流量不計入"))
        XCTAssertEqual(LocalForecastPresentation.describe(assessment: nil, forecast: nil, hasGaps: true).level, "unknown")
        XCTAssertTrue(LocalForecastPresentation.describe(assessment: assessment,
            forecast: .init(earliestSeconds: 0, latestSeconds: 0, limitingBudget: .upload), hasGaps: false).message.contains("達設定上限"))
        XCTAssertTrue(LocalForecastPresentation.describe(assessment: assessment,
            forecast: .init(earliestSeconds: .nan, latestSeconds: 10, limitingBudget: .download), hasGaps: false).message.contains("暫無可靠速率推估"))
    }
    func testForecastSeparatesUnobservedAndUnattributedTraffic() throws {
        let assessment = try XCTUnwrap(LocalQuotaPolicy.assess(received: 80, sent: 10,
            receiveLimit: 100, sendLimit: 100, totalLimit: 200))
        let forecast = QuotaForecast(earliestSeconds: 30, latestSeconds: 50, limitingBudget: .download)
        let unattributed = LocalForecastPresentation.describe(assessment: assessment,
            forecast: forecast, hasGaps: false, hasUnattributedTraffic: true)
        XCTAssertTrue(unattributed.message.contains("未歸類流量不計入"))
        XCTAssertFalse(unattributed.message.contains("未觀測流量不計入"))
        let both = LocalForecastPresentation.describe(assessment: assessment,
            forecast: nil, hasGaps: true, hasUnattributedTraffic: true)
        XCTAssertTrue(both.message.contains("未歸類流量不計入"))
        XCTAssertTrue(both.message.contains("未觀測流量不計入"))
        let normal = LocalForecastPresentation.describe(assessment: assessment,
            forecast: forecast, hasGaps: false)
        XCTAssertFalse(normal.message.contains("不計入"))
    }
    func testPolicyConsidersUploadAndTotal() throws {
        let assessment = try XCTUnwrap(LocalQuotaPolicy.assess(received: 0, sent: 380, receiveLimit: 700, sendLimit: 400, totalLimit: 1100))
        XCTAssertEqual(assessment.tier, .critical)
        XCTAssertEqual(assessment.limitingBudget, .upload)
        XCTAssertNil(LocalQuotaPolicy.assess(received: 0, sent: 0, receiveLimit: 0, sendLimit: 400, totalLimit: 1100))
    }
    func testLedgerDoesNotReopenOnClockRollbackOrDisabledFutureDay() {
        var ledger = QuotaAlertLedger()
        let today = "2026-11-28"
        XCTAssertTrue(ledger.shouldNotify(day: today, scope: .dorm, tier: .warning, enabled: true))
        XCTAssertFalse(ledger.shouldNotify(day: "2026-11-27", scope: .dorm, tier: .critical, enabled: true))
        XCTAssertFalse(ledger.shouldNotify(day: "2026-11-29", scope: .dorm, tier: .critical, enabled: false))
        XCTAssertFalse(ledger.shouldNotify(day: "2026-11-29", scope: .unknown, tier: .critical, enabled: true))
        XCTAssertFalse(ledger.shouldNotify(day: today, scope: .dorm, tier: .warning, enabled: true))
        XCTAssertTrue(ledger.shouldNotify(day: today, scope: .dorm, tier: .high, enabled: true))
    }
    func testLedgerIsPerScopeAndDay() {
        var ledger = QuotaAlertLedger()
        XCTAssertTrue(ledger.shouldNotify(day: "a", scope: .dorm, tier: .warning, enabled: true))
        XCTAssertFalse(ledger.shouldNotify(day: "a", scope: .dorm, tier: .warning, enabled: true))
        XCTAssertFalse(ledger.shouldNotify(day: "a", scope: .dorm, tier: .high, enabled: false))
        XCTAssertTrue(ledger.shouldNotify(day: "a", scope: .dorm, tier: .high, enabled: true))
        XCTAssertTrue(ledger.shouldNotify(day: "a", scope: .campusWifi, tier: .warning, enabled: true))
        XCTAssertTrue(ledger.shouldNotify(day: "b", scope: .dorm, tier: .warning, enabled: true))
    }
}
