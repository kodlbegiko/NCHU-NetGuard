import Foundation

/// Manual local event archive, isolated from the quota ledger.
/// Requires a single serial caller. No addresses or process identity.
public struct TrafficEventArchive: Sendable {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("events.json") }
    private let maxBytes = 2 * 1024 * 1024
    public init(directory: URL) { self.directory = directory }

    public func read() throws -> [TrafficObservationEvent] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        guard try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ContractError.invalidField("eventArchive")
        }
        guard fm.fileExists(atPath: file.path) else { return [] }
        let attrs = try fm.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes else {
            throw ContractError.invalidField("eventArchive")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maxBytes {
            let chunk = try handle.read(upToCount: min(65_536, maxBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maxBytes else { throw ContractError.invalidField("eventArchive") }
        let rows = try JSONDecoder().decode([TrafficObservationEvent].self, from: data)
        guard rows.count <= 1000, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy(\.isValid) else { throw ContractError.invalidField("eventArchive") }
        return rows.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }

    public func save(_ events: [TrafficObservationEvent]) throws {
        guard events.count <= 100, Set(events.map(\.id)).count == events.count,
              events.allSatisfy(\.isValid) else { throw ContractError.invalidField("eventArchive") }
        var rows = Dictionary(uniqueKeysWithValues: try read().map { ($0.id, $0) })
        for event in events {
            if let prior = rows[event.id], prior != event { throw ContractError.invalidField("eventArchive") }
            rows[event.id] = event
        }
        guard rows.count <= 1000 else { throw ContractError.invalidField("eventArchive") }
        try write(Array(rows.values))
    }

    public func clear() throws {
        // Validate before overwriting; preserve corrupted or unrecognized files.
        _ = try read()
        try write([])
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
