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
}
