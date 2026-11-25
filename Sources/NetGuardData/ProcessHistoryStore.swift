import Foundation

public struct ProcessHistoryRow: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let download: UInt64
    public let upload: UInt64
    public var id: String { name }
    public var total: UInt64 { download + upload }
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

/// Separate local, opt-in process-label history. One serial caller, atomic daily
/// file replacement, bounded file size. No PID, IP, executable path or quota data.
public struct ProcessHistoryStore {
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
    public func read(day: String) throws -> ProcessHistoryDay {
        let path = try url(day)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .init(day: day, buckets: [])
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes else { throw HistoryStoreError.invalidRecord }
        let data = try Data(contentsOf: path)
        guard data.count <= maxBytes else { throw HistoryStoreError.invalidRecord }
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
        let bucket = try ProcessHistoryBucket(session: bucket.session, hour: bucket.hour, intervals: bucket.intervals, rows: bucket.rows, limited: bucket.limited)
        let path = try url(day)
        var records = try read(day: day).buckets
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
