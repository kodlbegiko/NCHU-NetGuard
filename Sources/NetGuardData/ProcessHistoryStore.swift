import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Cooperating writers use a stable lock file, never the replaced data inode.
/// No blocking on another writer; callers must report/retry a busy write.
package enum HistoryFileAccess {
    package static func withWriteLock<T>(directory: URL, _ body: () throws -> T) throws -> T {
        try withDirectoryLock(directory: directory, name: ".netguard-history.lock") { _ in try body() }
    }

    private static func withDirectoryLock<T>(directory: URL, name: String,
                                             _ body: (Int32) throws -> T) throws -> T {
        guard directory.isFileURL else { throw HistoryStoreError.invalidRecord }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw HistoryStoreError.invalidRecord }
        defer { _ = close(parent) }
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw HistoryStoreError.invalidRecord }
        defer { _ = close(fd) }
        try validate(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw HistoryStoreError.database("history writer busy") }
        defer { _ = flock(fd, LOCK_UN) }
        return try body(parent)
    }

    static func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_uid == geteuid() else { throw HistoryStoreError.invalidRecord }
    }

    package static func read(_ url: URL, limit: Int) throws -> Data? {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parent < 0 {
            if errno == ENOENT { return nil }
            throw HistoryStoreError.invalidRecord
        }
        defer { _ = close(parent) }
        return try read(parent: parent, name: url.lastPathComponent, limit: limit)
    }

    private static func read(parent: Int32, name: String, limit: Int) throws -> Data? {
        guard (1...4_194_304).contains(limit) else { throw HistoryStoreError.invalidRecord }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw HistoryStoreError.invalidRecord
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try validate(fd)
        var data = Data()
        while data.count <= limit {
            let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw HistoryStoreError.invalidRecord }
        return data
    }

    /// Delete only the exact bytes previously inspected by the caller.
    /// This serializes cooperating writers; an unrelated same-user process
    /// can still race. Never use it as proof of authorization.
    package static func removeIfUnchanged(_ url: URL, expected: Data, limit: Int) throws {
        guard url.isFileURL, (1...4_194_304).contains(limit), expected.count <= limit,
              !url.lastPathComponent.isEmpty, url.lastPathComponent != ".", url.lastPathComponent != ".."
        else { throw HistoryStoreError.invalidRecord }
        let name = url.lastPathComponent
        try withDirectoryLock(directory: url.deletingLastPathComponent(), name: name + ".lock") { parent in
            guard try read(parent: parent, name: name, limit: limit) == expected
            else { throw HistoryStoreError.database("state changed by another writer") }
            guard unlinkat(parent, name, 0) == 0 else { throw HistoryStoreError.database("state removal") }
            guard fsync(parent) == 0 else { throw HistoryStoreError.database("state removal durability unknown") }
        }
    }

    /// Atomic compare-and-replace for a single local state file. Cooperation
    /// is required; this does not defend against arbitrary same-user writers.
    /// The temp inode is private from creation. A sync failure after rename
    /// is ambiguous; the caller must stop writing, not blindly retry.
    package static func replaceIfUnchanged(_ url: URL, expected: Data?, data: Data, limit: Int) throws {
        guard url.isFileURL, (1...4_194_304).contains(limit), data.count <= limit,
              expected.map({ $0.count <= limit }) ?? true,
              !url.lastPathComponent.isEmpty, url.lastPathComponent != ".", url.lastPathComponent != ".."
        else { throw HistoryStoreError.invalidRecord }
        let name = url.lastPathComponent
        try withDirectoryLock(directory: url.deletingLastPathComponent(), name: name + ".lock") { parent in
            guard try read(parent: parent, name: name, limit: limit) == expected
            else { throw HistoryStoreError.database("state changed by another writer") }
            let temp = ".netguard-state-" + UUID().uuidString
            let fd = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw HistoryStoreError.database("state temporary file") }
            defer { _ = unlinkat(parent, temp, 0) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0 else { throw HistoryStoreError.database("state sync") }
            try handle.close()
            guard renameat(parent, temp, parent, name) == 0 else {
                throw HistoryStoreError.database("state replace")
            }
            guard fsync(parent) == 0 else {
                throw HistoryStoreError.database("state durability unknown")
            }
        }
    }
}

public struct ProcessHistoryRow: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let download: UInt64
    public let upload: UInt64
    public var id: String { name }
    public var total: UInt64 { download + upload }
    private enum CodingKeys: String, CodingKey { case name, download, upload }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: values.decode(String.self, forKey: .name),
                      download: values.decode(UInt64.self, forKey: .download),
                      upload: values.decode(UInt64.self, forKey: .upload))
    }
    public init(name: String, download: UInt64, upload: UInt64) throws {
        let (_, overflow) = download.addingReportingOverflow(upload)
        guard !name.isEmpty, name.utf8.count <= 128,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !overflow else { throw HistoryStoreError.invalidRecord }
        self.name = name; self.download = download; self.upload = upload
    }
}
public struct ProcessHistoryBucket: Codable, Equatable, Sendable, Identifiable {
    public let session: UUID
    public let hour: Int
    public let intervals: Int
    public let rows: [ProcessHistoryRow]
    public let limited: Bool
    public var id: String { session.uuidString + "-" + String(hour) }
    private enum CodingKeys: String, CodingKey { case session, hour, intervals, rows, limited }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(session: c.decode(UUID.self, forKey: .session), hour: c.decode(Int.self, forKey: .hour),
                      intervals: c.decode(Int.self, forKey: .intervals), rows: c.decode([ProcessHistoryRow].self, forKey: .rows),
                      limited: c.decode(Bool.self, forKey: .limited))
    }
    public init(session: UUID, hour: Int, intervals: Int, rows: [ProcessHistoryRow], limited: Bool) throws {
        guard (0..<24).contains(hour), intervals > 0, intervals <= 100_000, rows.count <= 1024,
              Set(rows.map(\.name)).count == rows.count else { throw HistoryStoreError.invalidRecord }
        for row in rows { _ = try ProcessHistoryRow(name: row.name, download: row.download, upload: row.upload) }
        self.session = session; self.hour = hour; self.intervals = intervals
        self.rows = rows.sorted { $0.name < $1.name }; self.limited = limited
    }
}
public struct ProcessHistoryDay: Equatable, Sendable {
    public let day: String
    public let buckets: [ProcessHistoryBucket]
    public var intervals: Int { buckets.reduce(0) { $0 + $1.intervals } }
    public var limited: Bool { buckets.contains(where: \.limited) }
    public func totals(hour: Int? = nil) throws -> [ProcessHistoryRow] {
        var map: [String: ProcessHistoryRow] = [:]
        for bucket in buckets where hour == nil || bucket.hour == hour {
            for row in bucket.rows {
                let (d, od) = (map[row.name]?.download ?? 0).addingReportingOverflow(row.download)
                let (u, ou) = (map[row.name]?.upload ?? 0).addingReportingOverflow(row.upload)
                guard !od, !ou else { throw HistoryStoreError.invalidRecord }
                map[row.name] = try ProcessHistoryRow(name: row.name, download: d, upload: u)
            }
        }
        return map.values.sorted { $0.total == $1.total ? $0.name < $1.name : $0.total > $1.total }
    }
}

/// Separate local, opt-in process-label history. Cooperating writer lock, atomic daily
/// file replacement, bounded file size. No PID, IP, executable path or quota data.
public struct ProcessHistoryStore: Sendable {
    public let directory: URL
    private let maxBytes = 2 * 1024 * 1024
    public init(directory: URL) { self.directory = directory }
    public static func hour(at date: Date) -> (day: String, hour: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        return (f.string(from: date), calendar.component(.hour, from: date))
    }
    private func url(_ day: String) throws -> URL {
        _ = try HistoryDay(day: day, total: 0, download: nil, upload: nil)
        return directory.appendingPathComponent(day + ".json")
    }
    /// Only regular files with validated calendar-day names are managed.
    /// Foreign files, symlinks and subdirectories are never deletion targets.
    public func storedDays() throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw HistoryStoreError.invalidRecord
        }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return try files.compactMap { file -> String? in
            guard file.pathExtension == "json" else { return nil }
            let day = file.deletingPathExtension().lastPathComponent
            guard (try? url(day)) != nil else { return nil }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return day
        }.sorted(by: >)
    }

    /// Keep the current Taipei calendar day and the preceding days. Future
    /// records are preserved on clock rollback; unrelated files are untouched.
    @discardableResult
    public func prune(keepingDays: Int, now: Date = Date()) throws -> Int {
        guard [7, 30, 90].contains(keepingDays), now.timeIntervalSince1970.isFinite else {
            throw HistoryStoreError.invalidRecord
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        guard let cutoff = calendar.date(byAdding: .day, value: 1 - keepingDays, to: now)
        else { throw HistoryStoreError.invalidRecord }
        let earliest = Self.hour(at: cutoff).day
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try HistoryFileAccess.withWriteLock(directory: directory) {
            let expired = try storedDays().filter { $0 < earliest }
            for day in expired { try removeLocked(day: day) }
            return expired.count
        }
    }

    public func remove(day: String) throws {
        _ = try url(day)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try HistoryFileAccess.withWriteLock(directory: directory) { try removeLocked(day: day) }
    }

    private func removeLocked(day: String) throws {
        let file = try url(day)
        guard try storedDays().contains(day) else { return }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HistoryStoreError.invalidRecord
        }
        try FileManager.default.removeItem(at: file)
    }

    @discardableResult
    public func removeAllHistory() throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try HistoryFileAccess.withWriteLock(directory: directory) {
            let days = try storedDays()
            for day in days { try removeLocked(day: day) }
            return days.count
        }
    }

    public func read(day: String) throws -> ProcessHistoryDay {
        let path = try url(day)
        guard let data = try HistoryFileAccess.read(path, limit: maxBytes) else {
            return .init(day: day, buckets: [])
        }
        let decoded = try JSONDecoder().decode([ProcessHistoryBucket].self, from: data)
        guard decoded.count <= 512, Set(decoded.map(\.id)).count == decoded.count else { throw HistoryStoreError.invalidRecord }
        let checked = try decoded.map { try ProcessHistoryBucket(session: $0.session, hour: $0.hour, intervals: $0.intervals, rows: $0.rows, limited: $0.limited) }
        let report = ProcessHistoryDay(day: day, buckets: checked)
        _ = try report.totals()
        return report
    }
    /// A cumulative snapshot replaces the same session/hour only if monotonic.
    /// Replaying an identical snapshot is idempotent; distinct sessions coexist.
    public func save(day: String, bucket: ProcessHistoryBucket) throws {
        try save(day: day, bucket: bucket, allowedLabels: nil)
    }

    func save(day: String, bucket: ProcessHistoryBucket, allowedLabels: Set<String>?) throws {
        try HistoryFileAccess.withWriteLock(directory: directory) {
            try saveLocked(day: day, bucket: bucket, allowedLabels: allowedLabels)
        }
    }

    private func saveLocked(day: String, bucket: ProcessHistoryBucket, allowedLabels: Set<String>?) throws {
        let bucket = try ProcessHistoryBucket(session: bucket.session, hour: bucket.hour, intervals: bucket.intervals, rows: bucket.rows, limited: bucket.limited)
        let path = try url(day)
        var records = try read(day: day).buckets
        if let allowedLabels {
            guard (records + [bucket]).allSatisfy({ $0.rows.allSatisfy { allowedLabels.contains($0.name) } }) else {
                throw HistoryStoreError.invalidRecord
            }
        }
        if let index = records.firstIndex(where: { $0.id == bucket.id }) {
            let prior = records[index]
            let newer = Dictionary(uniqueKeysWithValues: bucket.rows.map { ($0.name, $0) })
            guard bucket.intervals >= prior.intervals, !prior.limited || bucket.limited,
                  prior.rows.allSatisfy({ old in
                      guard let new = newer[old.name] else { return false }
                      return new.download >= old.download && new.upload >= old.upload
                  }), bucket.intervals != prior.intervals || bucket == prior else { throw HistoryStoreError.invalidRecord }
            records[index] = bucket
        } else {
            guard records.count < 512 else { throw HistoryStoreError.invalidRecord }
            records.append(bucket)
        }
        _ = try ProcessHistoryDay(day: day, buckets: records).totals()
        let data = try JSONEncoder().encode(records)
        guard data.count <= maxBytes else { throw HistoryStoreError.invalidRecord }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}


/// Descriptor for the legacy user-controlled next-login configuration.
/// No registration, launchctl or process control. Ownership is intentionally
/// conservative: a moved app or extra plist keys requires manual review.
public enum LoginItemConfiguration {
    public static let label = "tw.edu.nchu.dorm.traffic"
    public static let maximumBytes = 16_384
    private static func fields(executable: String) throws -> [String: Any] {
        guard executable.hasPrefix("/"), executable.utf8.count <= 4096,
              !executable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw HistoryStoreError.invalidRecord }
        return ["Label": label, "ProgramArguments": [executable], "RunAtLoad": true, "ProcessType": "Interactive"]
    }
    public static func encode(executable: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: fields(executable: executable), format: .xml, options: 0)
    }
    public static func matches(_ data: Data, executable: String) -> Bool {
        guard data.count <= maximumBytes, let expected = try? fields(executable: executable),
              let actual = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              Set(actual.keys) == Set(expected.keys),
              let flag = actual["RunAtLoad"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID(),
              flag.boolValue else { return false }
        return actual["Label"] as? String == label &&
               actual["ProgramArguments"] as? [String] == [executable] &&
               actual["ProcessType"] as? String == "Interactive"
    }
}
