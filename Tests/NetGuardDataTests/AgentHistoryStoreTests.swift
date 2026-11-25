import Foundation
import XCTest
import NetGuardData

final class AgentHistoryStoreTests: XCTestCase {
    func testOnlyAllowlistedLabelsAndIdempotentSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentHistoryStore(directory: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = ProcessHistoryStore.hour(at: now)
        let id = UUID()
        let row = try ProcessHistoryRow(name: "Codex", download: 10, upload: 2)
        let bucket = try ProcessHistoryBucket(session: id, hour: key.hour, intervals: 1, rows: [row], limited: false)
        try store.save(day: key.day, bucket: bucket)
        try store.save(day: key.day, bucket: bucket)
        let days = try store.readRecent(now: now)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(try days[0].totals().first?.total, 12)
        XCTAssertTrue(days[1].buckets.isEmpty)
        let bad = try ProcessHistoryBucket(session: UUID(), hour: key.hour, intervals: 1,
            rows: [ProcessHistoryRow(name: "unexpected", download: 1, upload: 1)], limited: false)
        XCTAssertThrowsError(try store.save(day: key.day, bucket: bad))
        XCTAssertEqual(try store.readRecent(now: now)[0].buckets.count, 1)
        XCTAssertEqual(try store.removeAll(), 1)
        XCTAssertTrue(try store.readRecent(now: now)[0].buckets.isEmpty)
    }

    func testRejectsExistingUnexpectedLabels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = ProcessHistoryStore.hour(at: now)
        let bucket = try ProcessHistoryBucket(session: UUID(), hour: key.hour, intervals: 1,
            rows: [ProcessHistoryRow(name: "other", download: 1, upload: 0)], limited: false)
        try ProcessHistoryStore(directory: root).save(day: key.day, bucket: bucket)
        XCTAssertThrowsError(try AgentHistoryStore(directory: root).readRecent(now: now))
    }
}
