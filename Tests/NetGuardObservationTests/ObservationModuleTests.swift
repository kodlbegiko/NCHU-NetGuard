import XCTest
import NetGuardObservation

final class ObservationModuleTests: XCTestCase {
    func testStandaloneParserAndQuality() {
        XCTAssertEqual(AppTrafficParser.parse("Example.1,4,5\n"),
                       [AppTrafficObservation(name: "Example", bytes: 9)])
        var window = NetworkQualityWindow()
        window.ingest(latency: 25, uptime: 1)
        window.ingest(latency: 30, uptime: 2)
        window.ingest(latency: 35, uptime: 3)
        XCTAssertEqual(window.state(at: 3), .responsive)
    }

    func testLatencyMedianAndMeanConsecutiveChange() throws {
        var window = NetworkQualityWindow()
        for (index, value) in [10.0, 30.0, 20.0, 40.0].enumerated() {
            window.ingest(latency: value, uptime: Double(index + 1))
        }
        let result = try XCTUnwrap(window.summary(at: 4))
        XCTAssertEqual(result.sampleCount, 4)
        XCTAssertEqual(result.medianMilliseconds, 25)
        XCTAssertEqual(result.meanChangeMilliseconds, 50.0 / 3.0, accuracy: 0.000001)
        XCTAssertNil(window.summary(at: 125))
        window.ingest(latency: nil, uptime: 5)
        XCTAssertNil(window.summary(at: 5))
    }

    func testThroughputWindowResetsOnGapsAndIdentityChange() {
        var window = ThroughputWindow()
        window.ingest(identity: "a", uptime: 1, download: 0, upload: 100)
        window.ingest(identity: "a", uptime: 2, download: 200, upload: 0)
        XCTAssertEqual(window.recent(at: 2).count, 2)
        XCTAssertEqual(window.recent(at: 2).first?.downloadBytesPerSecond, 0)
        XCTAssertTrue(window.recent(at: 8).isEmpty)
        window.ingest(identity: "a", uptime: 8, download: 10, upload: 20)
        XCTAssertEqual(window.recent(at: 8).count, 1)
        window.ingest(identity: "b", uptime: 9, download: 30, upload: 40)
        XCTAssertEqual(window.recent(at: 9).count, 1)
        window.ingest(identity: "b", uptime: 10, download: nil, upload: 0)
        XCTAssertTrue(window.recent(at: 10).isEmpty)
    }

    func testThroughputBoundsAndInvalidSamples() {
        var window = ThroughputWindow()
        for index in 0..<500 {
            window.ingest(identity: "a", uptime: Double(index) * 0.25, download: 1, upload: 2)
        }
        XCTAssertEqual(window.recent(at: 124.75).count, 120)
        XCTAssertTrue(window.recent(at: 124).isEmpty)
        window.ingest(identity: "a", uptime: 125, download: .infinity, upload: 0)
        XCTAssertTrue(window.recent(at: 125).isEmpty)
    }

}
