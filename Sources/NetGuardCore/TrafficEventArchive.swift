import Foundation

/// Manual local event archive, isolated from the quota ledger.
/// Cooperating writer lock. No addresses or process identity.
public struct TrafficEventArchive: Sendable {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("events.json") }
    private let maxBytes = 2 * 1024 * 1024
    public init(directory: URL) { self.directory = directory }

    public func read() throws -> [TrafficObservationEvent] {
        guard let data = try HistoryFileAccess.read(file, limit: maxBytes) else { return [] }
        let rows = try JSONDecoder().decode([TrafficObservationEvent].self, from: data)
        guard rows.count <= 1000, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy(\.isValid) else { throw ContractError.invalidField("eventArchive") }
        return rows.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }

    public func save(_ events: [TrafficObservationEvent]) throws {
        guard events.count <= 100, Set(events.map(\.id)).count == events.count,
              events.allSatisfy(\.isValid) else { throw ContractError.invalidField("eventArchive") }
        try HistoryFileAccess.withWriteLock(directory: directory) {
        var rows = Dictionary(uniqueKeysWithValues: try read().map { ($0.id, $0) })
        for event in events {
            if let prior = rows[event.id], prior != event { throw ContractError.invalidField("eventArchive") }
            rows[event.id] = event
        }
        guard rows.count <= 1000 else { throw ContractError.invalidField("eventArchive") }
        try write(Array(rows.values))
        }
    }

    public func clear() throws {
        // Validate before overwriting; preserve corrupted or unrecognized files.
        try HistoryFileAccess.withWriteLock(directory: directory) {
            _ = try read()
            try write([])
        }
    }

    private func write(_ rows: [TrafficObservationEvent]) throws {
        let data = try JSONEncoder().encode(rows)
        guard data.count <= maxBytes else { throw ContractError.invalidField("eventArchive") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
