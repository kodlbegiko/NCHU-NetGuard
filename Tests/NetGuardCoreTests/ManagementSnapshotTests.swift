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

    func testCurrentProcessSearchAndOrdering() {
        let rows: [ProcessSampleRow] = [.init(name: "Safari", bytes: 20), .init(name: "Codex", bytes: 50), .init(name: "Safari Helper", bytes: 5)]
        XCTAssertEqual(ProcessSamplePresentation.visible(rows, query: " SAFARI ", order: .ascendingBytes).map(\.name), ["Safari Helper", "Safari"])
        XCTAssertEqual(ProcessSamplePresentation.visible(rows, query: "", order: .descendingBytes).map(\.name), ["Codex", "Safari", "Safari Helper"])
        XCTAssertEqual(ProcessSamplePresentation.visible(rows, query: "absent", order: .name), [])
    }


    func testPhysicalRatesAndTunnelEvidenceAreIndependent() {
        let rate = ObservedInterfaceRate(download: 0, upload: 20)
        let result = ManagementSnapshot(scopes: ["en0": .dorm, "en1": .unknown], defaultInterface: "utun4",
            connectionKnown: true, latencyStatus: "未量測", processRows: [], processAge: nil,
            focusEnabled: false, diagnosticInput: .init(connected: true, scope: .unknown, persistenceHealthy: true,
                sampleGapCount: 0, providerFresh: false), providerStatus: "fixture",
            rates: rate.map { ["en0": $0] } ?? [:], tunnelCandidates: ["utun4"])
        XCTAssertEqual(result.interfaces.first?.rate, rate)
        XCTAssertNil(result.interfaces.last?.rate)
        XCTAssertFalse(result.interfaces.contains(where: \.isDefault))
        XCTAssertTrue(result.tunnelStatus.contains("疑似隧道"))
        XCTAssertNil(ObservedInterfaceRate(download: .nan, upload: 0))
        XCTAssertNil(ObservedInterfaceRate(download: 0, upload: -1))
    }

}
