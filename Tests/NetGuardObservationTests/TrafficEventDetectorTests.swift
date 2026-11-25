import Foundation
import XCTest
import NetGuardObservation

final class TrafficEventDetectorTests: XCTestCase {
    private func sample(_ detector: inout TrafficEventDetector, _ time: Double,
                        rate: Double, identity: String = "a") {
        detector.ingest(identity: identity, uptime: time,
            date: Date(timeIntervalSince1970: 1_800_000_000 + time), download: rate, upload: 0)
    }
    func testSurgeRequiresPriorBaselineAndDoesNotRepeatDuringEpisode() {
        var detector = TrafficEventDetector()
        for time in 0..<20 { sample(&detector, Double(time), rate: 100_000) }
        sample(&detector, 20, rate: 2_000_000)
        sample(&detector, 21, rate: 2_000_000)
        XCTAssertEqual(detector.recent().map(\.kind), [.surge])
        XCTAssertEqual(detector.recent().first?.referenceBytesPerSecond, 100_000)
    }
    func testSustainedHighRequiresContinuousDurationAndRearms() {
        var detector = TrafficEventDetector()
        for time in 0...9 { sample(&detector, Double(time), rate: 6_000_000) }
        XCTAssertTrue(detector.recent().isEmpty)
        sample(&detector, 10, rate: 6_000_000)
        sample(&detector, 11, rate: 6_000_000)
        XCTAssertEqual(detector.recent().map(\.kind), [.sustainedHigh])
        sample(&detector, 12, rate: 0)
        for time in 13...23 { sample(&detector, Double(time), rate: 6_000_000) }
        XCTAssertEqual(detector.recent().filter { $0.kind == .sustainedHigh }.count, 2)
    }
    func testGapAndIdentityChangeNeverBridgeHighEpisode() {
        var detector = TrafficEventDetector()
        for time in 0...8 { sample(&detector, Double(time), rate: 6_000_000) }
        detector.ingest(identity: nil, uptime: 9, date: Date(), download: nil, upload: nil)
        detector.ingest(identity: nil, uptime: 10, date: Date(), download: nil, upload: nil)
        sample(&detector, 11, rate: 6_000_000)
        sample(&detector, 12, rate: 6_000_000, identity: "b")
        sample(&detector, 19, rate: 6_000_000, identity: "b")
        XCTAssertEqual(detector.recent().map(\.kind), [.observationGap, .observationGap])
        detector.resetContinuity()
        sample(&detector, 30, rate: 6_000_000)
        XCTAssertEqual(detector.recent().count, 2)
    }
    func testBoundedHistoryAndClear() {
        var detector = TrafficEventDetector()
        for time in 0..<150 {
            sample(&detector, Double(time * 2), rate: 0)
            detector.ingest(identity: nil, uptime: Double(time * 2 + 1), date: Date(), download: nil, upload: nil)
        }
        XCTAssertEqual(detector.recent().count, 100)
        XCTAssertEqual(Set(detector.recent().map(\.id)).count, 100)
        detector.clear()
        XCTAssertTrue(detector.recent().isEmpty)
    }
}
