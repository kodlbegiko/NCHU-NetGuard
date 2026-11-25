import Foundation
import XCTest
import NetGuardData

final class ConnectionHistoryStoreTests: XCTestCase {
    private func withStore(_ body: (ConnectionHistoryStore) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(ConnectionHistoryStore(directory: url))
    }
    private func row(id: UUID = UUID(), received: UInt64 = 10, sent: UInt64 = 5) throws -> SavedConnectionSession {
        try .init(id: id, label: "Hotspot", savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                  received: received, sent: sent, limitBytes: 2_000_000_000, intervals: 1)
    }

    func testIdempotentSaveAndSameLabelSessionsRemainSeparate() throws {
        try withStore { store in
            let first = try row()
            let second = try row()
            try store.save(first)
            try store.save(first)
            try store.save(second)
            let reopened = ConnectionHistoryStore(directory: store.directory)
            XCTAssertEqual(Set(try reopened.read().map(\.id)), Set([first.id, second.id]))
            XCTAssertEqual(try reopened.read().count, 2)
            XCTAssertThrowsError(try store.save(row(id: first.id, received: 20)))
            XCTAssertEqual(try reopened.read().count, 2)
        }
    }
    func testDeleteOnlySelectedRecord() throws {
        try withStore { store in
            let first = try row()
            let second = try row()
            try store.save(first)
            try store.save(second)
            try store.remove(id: first.id)
            try store.remove(id: first.id)
            XCTAssertEqual(try store.read(), [second])
        }
    }
    func testCorruptDataIsNotOverwritten() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let url = store.directory.appendingPathComponent("sessions.json")
            let original = Data("invalid".utf8)
            try original.write(to: url)
            XCTAssertThrowsError(try store.save(row()))
            XCTAssertThrowsError(try store.remove(id: UUID()))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
    func testDecodedOverflowIsRejected() throws {
        let encoded = try JSONEncoder().encode(row())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["received"] = NSNumber(value: UInt64.max)
        object["sent"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(SavedConnectionSession.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testOversizedArchiveIsPreserved() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let url = store.directory.appendingPathComponent("sessions.json")
            let original = Data(repeating: 32, count: 2 * 1024 * 1024 + 1)
            try original.write(to: url)
            XCTAssertThrowsError(try store.save(row()))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
    func testInvalidRowsRejected() throws {
        XCTAssertThrowsError(try row(received: UInt64.max, sent: 1))
        XCTAssertThrowsError(try SavedConnectionSession(id: UUID(), label: "", savedAt: Date(),
            received: 0, sent: 0, limitBytes: 1_000_000_000, intervals: 1))
        XCTAssertThrowsError(try SavedConnectionSession(id: UUID(), label: "A", savedAt: Date(),
            received: 0, sent: 0, limitBytes: 1_000_000_000, intervals: 0))
    }
}
