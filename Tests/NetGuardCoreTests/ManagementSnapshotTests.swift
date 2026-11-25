import XCTest
import NetGuardCore

final class ManagementSnapshotTests: XCTestCase {
    private func snapshot(age: Double?, focus: Bool, known: Bool = true) -> ManagementSnapshot {
        ManagementSnapshot(scopes: ["en1": .unknown, "en0": .dorm], defaultInterface: "en0",
            connectionKnown: known, latencyStatus: "未量測",
            processRows: [.init(name: "A", bytes: 3), .init(name: "B", bytes: 10)],
            processAge: age, focusEnabled: focus,
            diagnosticInput: .init(connected: known, scope: .dorm, persistenceHealthy: true,
                                   sampleGapCount: 1, providerFresh: false),
            providerStatus: "校方未確認")
    }
    func testSortedInterfacesAndProcesses() {
        let result = snapshot(age: 5, focus: false)
        XCTAssertEqual(result.interfaces.map(\.name), ["en0", "en1"])
        XCTAssertTrue(result.interfaces[0].isDefault)
        XCTAssertEqual(result.processes.map(\.name), ["B", "A"])
        XCTAssertEqual(result.findings, [.incompleteSamples, .providerUnknown])
    }
    func testOldAndInvalidSamplesNeverAppearCurrent() {
        for age in [nil, -1, 31, Double.nan] as [Double?] {
            XCTAssertTrue(snapshot(age: age, focus: false).processes.isEmpty)
        }
        XCTAssertTrue(snapshot(age: 1, focus: true).processes.isEmpty)
    }
    func testUnknownConnectionDoesNotAssertDefault() {
        let result = snapshot(age: nil, focus: false, known: false)
        XCTAssertFalse(result.interfaces.contains(where: \.isDefault))
        XCTAssertEqual(result.findings.first, .connectionUnknown)
    }
}
