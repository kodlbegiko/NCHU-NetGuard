import Foundation
import XCTest
import NetGuardCore

final class HistoryBundleTests: XCTestCase {
    private func fixture(_ body: (URL, URL, ProcessHistoryStore, ConnectionHistoryStore, TrafficEventArchive) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("source.sqlite")
        let store = try HistoryStore(url: db)
        try store.upsert(HistoryDay(day: "2026-11-25", total: 15, download: 10, upload: 5))
        let process = ProcessHistoryStore(directory: root.appendingPathComponent("process"))
        let connections = ConnectionHistoryStore(directory: root.appendingPathComponent("connections"))
        let events = TrafficEventArchive(directory: root.appendingPathComponent("events"))
        try connections.save(SavedConnectionSession(id: UUID(), label: "Test", savedAt: Date(),
            received: 10, sent: 5, limitBytes: 1_000_000_000, intervals: 1))
        var detector = TrafficEventDetector()
        for t in 0...10 {
            detector.ingest(identity: "test", uptime: Double(t), date: Date(), download: 6_000_000, upload: 0)
        }
        try events.save(detector.recent())
        try body(root, db, process, connections, events)
    }

    func testBundleRoundTripAndExistingDestination() throws {
        try fixture { root, db, process, connections, events in
            let target = root.appendingPathComponent("backup")
            let summary = try HistoryBundle.create(database: db, process: process,
                connections: connections, events: events, destination: target)
            XCTAssertEqual(summary.database.recordedDays, 1)
            XCTAssertEqual(summary.processDays, 0)
            XCTAssertEqual(summary.connectionSessions, 1)
            XCTAssertEqual(summary.events, 1)
            XCTAssertEqual(try HistoryBundle.inspect(target), summary)
            XCTAssertThrowsError(try HistoryBundle.create(database: db, process: process,
                connections: connections, events: events, destination: target))
            XCTAssertEqual(try HistoryBundle.inspect(target), summary)
        }
    }

    func testTamperedPayloadAndUnexpectedFileRejected() throws {
        try fixture { root, db, process, connections, events in
            let target = root.appendingPathComponent("backup")
            _ = try HistoryBundle.create(database: db, process: process,
                connections: connections, events: events, destination: target)
            let unexpected = target.appendingPathComponent("unexpected")
            try Data().write(to: unexpected)
            XCTAssertThrowsError(try HistoryBundle.inspect(target))
            try FileManager.default.removeItem(at: unexpected)
            try Data("[]".utf8).write(to: target.appendingPathComponent("event-history/events.json"))
            XCTAssertThrowsError(try HistoryBundle.inspect(target))
        }
    }

    func testCorruptSourceDoesNotPublishDestination() throws {
        try fixture { root, db, process, connections, events in
            let corrupt = Data("invalid".utf8)
            let source = events.directory.appendingPathComponent("events.json")
            try corrupt.write(to: source)
            let target = root.appendingPathComponent("backup")
            XCTAssertThrowsError(try HistoryBundle.create(database: db, process: process,
                connections: connections, events: events, destination: target))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: source), corrupt)
        }
    }
}
