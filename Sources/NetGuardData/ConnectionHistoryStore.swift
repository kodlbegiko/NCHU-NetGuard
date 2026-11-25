import Foundation

/// A manually saved, stopped connection observation. The user label is not
/// a verified network identity. No addresses, SSID or hardware IDs are saved.
public struct SavedConnectionSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let label: String
    public let savedAt: Date
    public let received: UInt64
    public let sent: UInt64
    public let limitBytes: UInt64
    public let intervals: Int
    public var total: UInt64 { received + sent }
    private enum CodingKeys: String, CodingKey { case id, label, savedAt, received, sent, limitBytes, intervals }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: v.decode(UUID.self, forKey: .id), label: v.decode(String.self, forKey: .label),
                      savedAt: v.decode(Date.self, forKey: .savedAt), received: v.decode(UInt64.self, forKey: .received),
                      sent: v.decode(UInt64.self, forKey: .sent), limitBytes: v.decode(UInt64.self, forKey: .limitBytes),
                      intervals: v.decode(Int.self, forKey: .intervals))
    }

    public init(id: UUID, label: String, savedAt: Date, received: UInt64, sent: UInt64, limitBytes: UInt64, intervals: Int) throws {
        let (_, overflow) = received.addingReportingOverflow(sent)
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.utf8.count <= 80,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              savedAt.timeIntervalSince1970.isFinite,
              limitBytes % 1_000_000_000 == 0,
              (1...10_000).contains(limitBytes / 1_000_000_000),
              intervals > 0, !overflow else { throw HistoryStoreError.invalidRecord }
        self.id = id; self.label = label; self.savedAt = savedAt
        self.received = received; self.sent = sent; self.limitBytes = limitBytes; self.intervals = intervals
    }
}

/// Bounded, manually populated archive. Single serial caller required.
/// No automatic grouping, pruning, network matching or quota integration.
public struct ConnectionHistoryStore: Sendable {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("sessions.json") }
    private let maxBytes = 2 * 1024 * 1024
    public init(directory: URL) { self.directory = directory }

    public func read() throws -> [SavedConnectionSession] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        guard try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw HistoryStoreError.invalidRecord
        }
        guard fm.fileExists(atPath: file.path) else { return [] }
        let attrs = try fm.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes else { throw HistoryStoreError.invalidRecord }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maxBytes {
            let chunk = try handle.read(upToCount: min(65_536, maxBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maxBytes else { throw HistoryStoreError.invalidRecord }
        let rows = try JSONDecoder().decode([SavedConnectionSession].self, from: data)
        guard rows.count <= 1000, Set(rows.map(\.id)).count == rows.count else { throw HistoryStoreError.invalidRecord }
        return try rows.map {
            try SavedConnectionSession(id: $0.id, label: $0.label, savedAt: $0.savedAt,
                received: $0.received, sent: $0.sent, limitBytes: $0.limitBytes, intervals: $0.intervals)
        }.sorted { $0.savedAt == $1.savedAt ? $0.id.uuidString < $1.id.uuidString : $0.savedAt > $1.savedAt }
    }

    public func save(_ row: SavedConnectionSession) throws {
        _ = try SavedConnectionSession(id: row.id, label: row.label, savedAt: row.savedAt,
            received: row.received, sent: row.sent, limitBytes: row.limitBytes, intervals: row.intervals)
        var rows = try read()
        if let existing = rows.first(where: { $0.id == row.id }) {
            guard existing == row else { throw HistoryStoreError.invalidRecord }
            return
        }
        guard rows.count < 1000 else { throw HistoryStoreError.invalidRecord }
        rows.append(row)
        try write(rows)
    }

    public func remove(id: UUID) throws {
        let rows = try read()
        guard rows.contains(where: { $0.id == id }) else { return }
        try write(rows.filter { $0.id != id })
    }

    private func write(_ rows: [SavedConnectionSession]) throws {
        let data = try JSONEncoder().encode(rows)
        guard data.count <= maxBytes else { throw HistoryStoreError.invalidRecord }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
