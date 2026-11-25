import Foundation
import XCTest
import NetGuardCore

final class TrafficEventArchiveTests: XCTestCase {
    private func events() -> [TrafficObservationEvent] {
        var detector = TrafficEventDetector()
        for second in 0...10 {
            detector.ingest(identity: "local", uptime: Double(second),
                date: Date(timeIntervalSince1970: 1_800_000_000 + Double(second)),
                download: 6_000_000, upload: 0)
        }
        return detector.recent()
    }
    private func withArchive(_ body: (TrafficEventArchive) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try body(TrafficEventArchive(directory: path))
    }
    func testSaveReopenAndRetryAreIdempotent() throws {
        try withArchive { archive in
            let rows = events()
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(rows.allSatisfy(\.isValid))
            try archive.save(rows)
            try archive.save(rows)
            XCTAssertEqual(try TrafficEventArchive(directory: archive.directory).read(), rows)
            try archive.clear()
            XCTAssertTrue(try archive.read().isEmpty)
        }
    }
    func testHistoricalRulesSurviveConfigurationChange() throws {
        var detector = TrafficEventDetector()
        for second in 0...10 {
            detector.ingest(identity: "local", uptime: Double(second), date: Date(), download: 6_000_000, upload: 0)
        }
        let custom = try XCTUnwrap(TrafficEventRules(highMiB: 2, highSeconds: 5, surgeMiB: 1, surgeMultiplier: 4))
        detector.configure(custom)
        for second in 11...16 {
            detector.ingest(identity: "local", uptime: Double(second), date: Date(), download: 3_000_000, upload: 0)
        }
        XCTAssertEqual(detector.recent().map(\.rules), [custom, .standard])
        XCTAssertTrue(detector.recent().allSatisfy(\.isValid))
    }
    func testCorruptionAndDuplicateInputsDoNotOverwrite() throws {
        try withArchive { archive in
            let rows = events()
            XCTAssertThrowsError(try archive.save(rows + rows))
            try FileManager.default.createDirectory(at: archive.directory, withIntermediateDirectories: true)
            let file = archive.directory.appendingPathComponent("events.json")
            let corrupt = Data("invalid".utf8)
            try corrupt.write(to: file)
            XCTAssertThrowsError(try archive.save(rows))
            XCTAssertThrowsError(try archive.clear())
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
        }
    }
    func testDecodedInvalidEvidenceRejected() throws {
        try withArchive { archive in
            let encoded = try JSONEncoder().encode(try XCTUnwrap(events().first))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object["bytesPerSecond"] = 1
            let invalid = try JSONDecoder().decode(TrafficObservationEvent.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertFalse(invalid.isValid)
            XCTAssertThrowsError(try archive.save([invalid]))
        }
    }
}
