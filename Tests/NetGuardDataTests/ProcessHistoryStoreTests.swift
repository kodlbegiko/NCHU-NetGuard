import Foundation
import XCTest
import NetGuardData
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ProcessHistoryStoreTests: XCTestCase {
    private func withStore(_ body: (ProcessHistoryStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ProcessHistoryStore(directory: directory))
    }
    private func bucket(_ session: UUID, hour: Int = 10, intervals: Int = 1,
                        download: UInt64 = 10, upload: UInt64 = 5) throws -> ProcessHistoryBucket {
        try ProcessHistoryBucket(session: session, hour: hour, intervals: intervals,
            rows: [ProcessHistoryRow(name: "Fixture", download: download, upload: upload)], limited: false)
    }
    func testCompareAndReplaceRejectsStaleWriterAndSymlink() throws {
        try withStore { store in
            let file = store.directory.appendingPathComponent("state.json")
            let first = Data("first".utf8), second = Data("second".utf8)
            try HistoryFileAccess.replaceIfUnchanged(file, expected: nil, data: first, limit: 100)
            XCTAssertThrowsError(try HistoryFileAccess.replaceIfUnchanged(file, expected: nil, data: second, limit: 100))
            try HistoryFileAccess.replaceIfUnchanged(file, expected: first, data: second, limit: 100)
            XCTAssertThrowsError(try HistoryFileAccess.replaceIfUnchanged(file, expected: first, data: first, limit: 100))
            XCTAssertEqual(try HistoryFileAccess.read(file, limit: 100), second)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
            let link = store.directory.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertThrowsError(try HistoryFileAccess.replaceIfUnchanged(link, expected: second, data: first, limit: 100))
            XCTAssertEqual(try HistoryFileAccess.read(file, limit: 100), second)
        }
    }
    func testLoginItemConfigRejectsForeignAndChangedEntries() throws {
        let path = "/Applications/Fixture & Test.app/Contents/MacOS/NetGuard"
        let data = try LoginItemConfiguration.encode(executable: path)
        XCTAssertTrue(LoginItemConfiguration.matches(data, executable: path))
        XCTAssertFalse(LoginItemConfiguration.matches(data, executable: "/other"))
        XCTAssertFalse(LoginItemConfiguration.matches(Data("bad".utf8), executable: path))
        var fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        fields["RunAtLoad"] = 1
        let wrongType = try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
        XCTAssertFalse(LoginItemConfiguration.matches(wrongType, executable: path))
        fields["RunAtLoad"] = true
        fields["KeepAlive"] = true
        let foreign = try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
        XCTAssertFalse(LoginItemConfiguration.matches(foreign, executable: path))
        try withStore { store in
            let file = store.directory.appendingPathComponent("fixture.plist")
            try HistoryFileAccess.replaceIfUnchanged(file, expected: nil, data: data, limit: 16_384)
            try HistoryFileAccess.replaceIfUnchanged(file, expected: data, data: foreign, limit: 16_384)
            XCTAssertThrowsError(try HistoryFileAccess.removeIfUnchanged(file, expected: data, limit: 16_384))
            XCTAssertEqual(try HistoryFileAccess.read(file, limit: 16_384), foreign)
            try HistoryFileAccess.removeIfUnchanged(file, expected: foreign, limit: 16_384)
            XCTAssertNil(try HistoryFileAccess.read(file, limit: 16_384))
        }
    }
    func testCooperatingWriterLockPreservesHistory() throws {
        try withStore { store in
            let day = "2026-11-25"
            try store.save(day: day, bucket: bucket(UUID()))
            let fd = open(store.directory.appendingPathComponent(".netguard-history.lock").path, O_RDWR | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { return }
            defer { _ = flock(fd, LOCK_UN); _ = close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try store.save(day: day, bucket: bucket(UUID())))
            XCTAssertEqual(try store.read(day: day).buckets.count, 1)
        }
    }
    func testIdempotentSnapshotsAndRestartIsolation() throws {
        try withStore { store in
            let session = UUID()
            let first = try bucket(session)
            try store.save(day: "2026-11-25", bucket: first)
            try store.save(day: "2026-11-25", bucket: first)
            try store.save(day: "2026-11-25", bucket: bucket(session, intervals: 2, download: 20, upload: 10))
            try store.save(day: "2026-11-25", bucket: bucket(UUID(), hour: 11))
            let reopened = ProcessHistoryStore(directory: store.directory)
            let day = try reopened.read(day: "2026-11-25")
            XCTAssertEqual(day.intervals, 3)
            XCTAssertEqual(try day.totals().first?.download, 30)
            XCTAssertEqual(try day.totals(hour: 10).first?.upload, 10)
            XCTAssertTrue(try day.totals(hour: 12).isEmpty)
        }
    }
    func testStaleOrConflictingSnapshotCannotReplaceHistory() throws {
        try withStore { store in
            let session = UUID()
            try store.save(day: "2026-11-25", bucket: bucket(session, intervals: 2, download: 20))
            XCTAssertThrowsError(try store.save(day: "2026-11-25", bucket: bucket(session)))
            XCTAssertThrowsError(try store.save(day: "2026-11-25", bucket: bucket(session, intervals: 2, download: 21)))
            XCTAssertEqual(try store.read(day: "2026-11-25").totals().first?.download, 20)
        }
    }
    func testDateHourAndUnknownDistinction() throws {
        try withStore { store in
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T16:00:00Z"))
            let key = ProcessHistoryStore.hour(at: date)
            XCTAssertEqual(key.day, "2026-11-26")
            XCTAssertEqual(key.hour, 0)
            XCTAssertTrue(try store.read(day: key.day).buckets.isEmpty)
            let zero = try ProcessHistoryBucket(session: UUID(), hour: 0, intervals: 1, rows: [], limited: false)
            try store.save(day: key.day, bucket: zero)
            XCTAssertEqual(try store.read(day: key.day).intervals, 1)
            XCTAssertThrowsError(try store.read(day: "../unsafe"))
            XCTAssertThrowsError(try bucket(UUID(), hour: 24))
        }
    }
    func testCorruptFileAndOverflowNeverOverwrite() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let path = store.directory.appendingPathComponent("2026-11-25.json")
            let original = Data("invalid".utf8)
            try original.write(to: path)
            XCTAssertThrowsError(try store.save(day: "2026-11-25", bucket: bucket(UUID())))
            XCTAssertEqual(try Data(contentsOf: path), original)
            XCTAssertThrowsError(try ProcessHistoryRow(name: "App", download: UInt64.max, upload: 1))
            XCTAssertThrowsError(try ProcessHistoryRow(name: "Bad\nName", download: 1, upload: 0))
        }
    }

    func testDirectDecodeRejectsOverflowAndInvalidName() {
        for json in [
            #"{"name":"Fixture","download":18446744073709551615,"upload":1}"#,
            #"{"name":"","download":1,"upload":0}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(ProcessHistoryRow.self, from: Data(json.utf8)))
        }
    }
    func testDirectBucketDecodeValidatesHourAndDuplicateRows() throws {
        let session = UUID().uuidString
        let invalid = "{\"session\":\"\(session)\",\"hour\":24,\"intervals\":1,\"rows\":[],\"limited\":false}"
        XCTAssertThrowsError(try JSONDecoder().decode(ProcessHistoryBucket.self, from: Data(invalid.utf8)))
        let duplicate = "{\"session\":\"\(session)\",\"hour\":1,\"intervals\":1,\"rows\":[{\"name\":\"x\",\"download\":1,\"upload\":0},{\"name\":\"x\",\"download\":1,\"upload\":0}],\"limited\":false}"
        XCTAssertThrowsError(try JSONDecoder().decode(ProcessHistoryBucket.self, from: Data(duplicate.utf8)))
    }
    func testOversizedHistoryPreserved() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let path = store.directory.appendingPathComponent("2026-11-25.json")
            let payload = Data(repeating: 32, count: 2 * 1024 * 1024 + 1)
            try payload.write(to: path)
            XCTAssertThrowsError(try store.save(day: "2026-11-25", bucket: bucket(UUID())))
            XCTAssertEqual(try Data(contentsOf: path), payload)
        }
    }
    func testRetentionUsesTaipeiDaysAndPreservesFutureAndForeignFiles() throws {
        try withStore { store in
            for day in ["2026-11-18", "2026-11-19", "2026-11-25", "2026-11-26"] {
                try store.save(day: day, bucket: bucket(UUID()))
            }
            let foreign = store.directory.appendingPathComponent("notes.json")
            try Data("keep".utf8).write(to: foreign)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T08:00:00Z"))
            XCTAssertEqual(try store.prune(keepingDays: 7, now: now), 1)
            XCTAssertEqual(try store.storedDays(), ["2026-11-26", "2026-11-25", "2026-11-19"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
            XCTAssertThrowsError(try store.prune(keepingDays: 0, now: now))
        }
    }

    func testExplicitDeletionLeavesUnrelatedFilesAndSymlinks() throws {
        try withStore { store in
            try store.save(day: "2026-11-25", bucket: bucket(UUID()))
            let foreign = store.directory.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: foreign)
            let link = store.directory.appendingPathComponent("2026-11-24.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
            XCTAssertEqual(try store.removeAllHistory(), 1)
            XCTAssertTrue(try store.storedDays().isEmpty)
            XCTAssertEqual(try Data(contentsOf: foreign), Data("keep".utf8))
            XCTAssertEqual(try Data(contentsOf: link), Data("keep".utf8))
        }
    }

    func testDeletionIsIdempotentAndRejectsInvalidDates() throws {
        try withStore { store in
            XCTAssertEqual(try store.removeAllHistory(), 0)
            XCTAssertThrowsError(try store.remove(day: "../unsafe"))
            try store.save(day: "2026-11-25", bucket: bucket(UUID()))
            try store.remove(day: "2026-11-25")
            try store.remove(day: "2026-11-25")
            XCTAssertTrue(try store.storedDays().isEmpty)
        }
    }

}
