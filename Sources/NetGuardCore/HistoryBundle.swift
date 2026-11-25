import Foundation
import CryptoKit

public struct HistoryBundleSummary: Equatable, Sendable {
    public let database: HistoryBackupSummary
    public let processDays: Int
    public let connectionSessions: Int
    public let events: Int
}

private struct HistoryBundleManifest: Codable {
    struct Entry: Codable, Equatable {
        let path: String
        let bytes: Int
        let sha256: String
    }
    let version: Int
    let createdAt: Date
    let files: [Entry]
}

/// A portable history directory. Each component is validated independently.
/// Not a simultaneous snapshot of live counters or an active-store restore.
public enum HistoryBundle {
    private static let fm = FileManager.default
    private static let fixed = ["history.sqlite", "connection-history/sessions.json", "event-history/events.json"]
    private static let maxTotal = 256 * 1024 * 1024
    private static func fail() -> ContractError { .invalidField("historyBundle") }

    private static func directory(_ url: URL) throws {
        guard url.isFileURL, try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { throw fail() }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func read(_ url: URL, max: Int) throws -> Data {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber,
              size.int64Value >= 0, size.int64Value <= Int64(max) else { throw fail() }
        let data = try Data(contentsOf: url)
        guard data.count <= max else { throw fail() }
        return data
    }

    private static func inventory(_ root: URL, manifestPresent: Bool) throws -> [HistoryBundleManifest.Entry] {
        try directory(root)
        let expected = Set(["history.sqlite", "process-history", "connection-history", "event-history"] + (manifestPresent ? ["manifest.json"] : []))
        guard Set(try fm.contentsOfDirectory(atPath: root.path)) == expected else { throw fail() }
        for (folder, expectedFile) in [("connection-history", "sessions.json"), ("event-history", "events.json")] {
            let url = root.appendingPathComponent(folder)
            try directory(url)
            guard try fm.contentsOfDirectory(atPath: url.path) == [expectedFile] else { throw fail() }
        }
        let process = root.appendingPathComponent("process-history")
        try directory(process)
        let names = try fm.contentsOfDirectory(atPath: process.path)
        guard names.count <= 366 else { throw fail() }
        for name in names {
            guard name.hasSuffix(".json") else { throw fail() }
            let day = String(name.dropLast(5))
            _ = try HistoryDay(day: day, total: 0, download: nil, upload: nil)
        }
        var total = 0
        return try (fixed + names.map { "process-history/" + $0 }).sorted().map { path in
            let data = try read(root.appendingPathComponent(path), max: path == "history.sqlite" ? 64 * 1024 * 1024 : 2 * 1024 * 1024)
            total += data.count
            guard total <= maxTotal else { throw fail() }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return .init(path: path, bytes: data.count, sha256: hash)
        }
    }

    public static func create(database: URL, process: ProcessHistoryStore,
                              connections: ConnectionHistoryStore, events: TrafficEventArchive,
                              destination: URL) throws -> HistoryBundleSummary {
        guard destination.isFileURL, !fm.fileExists(atPath: destination.path) else { throw fail() }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".netguard-history-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        for folder in ["process-history", "connection-history", "event-history"] {
            try fm.createDirectory(at: temp.appendingPathComponent(folder), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try HistoryStore.backup(from: database, to: temp.appendingPathComponent("history.sqlite"))
        let encoder = JSONEncoder()
        let days = try process.storedDays()
        guard days.count <= 366 else { throw fail() }
        var processBytes = 0
        for day in days {
            let data = try encoder.encode(process.read(day: day).buckets)
            processBytes += data.count
            guard data.count <= 2 * 1024 * 1024, processBytes <= maxTotal else { throw fail() }
            try write(data, to: temp.appendingPathComponent("process-history/\(day).json"))
        }
        try write(encoder.encode(connections.read()), to: temp.appendingPathComponent("connection-history/sessions.json"))
        try write(encoder.encode(events.read()), to: temp.appendingPathComponent("event-history/events.json"))
        let entries = try inventory(temp, manifestPresent: false)
        let manifest = HistoryBundleManifest(version: 1, createdAt: Date(), files: entries)
        try write(encoder.encode(manifest), to: temp.appendingPathComponent("manifest.json"))
        let result = try inspect(temp)
        try fm.moveItem(at: temp, to: destination)
        return result
    }

    /// Untrusted manifests cannot supply paths to read. Inventory is derived
    /// from the fixed directory layout, then compared to the manifest.
    public static func inspect(_ root: URL) throws -> HistoryBundleSummary {
        try directory(root)
        let manifest = try JSONDecoder().decode(HistoryBundleManifest.self,
            from: read(root.appendingPathComponent("manifest.json"), max: 128 * 1024))
        guard manifest.version == 1, manifest.createdAt.timeIntervalSince1970.isFinite,
              manifest.files.count <= 369,
              manifest.files == (try inventory(root, manifestPresent: true)) else { throw fail() }
        let database = try HistoryBackupInspector.inspect(root.appendingPathComponent("history.sqlite"))
        let process = ProcessHistoryStore(directory: root.appendingPathComponent("process-history"))
        let days = try process.storedDays()
        for day in days { _ = try process.read(day: day) }
        let connections = try ConnectionHistoryStore(directory: root.appendingPathComponent("connection-history")).read()
        let events = try TrafficEventArchive(directory: root.appendingPathComponent("event-history")).read()
        return .init(database: database, processDays: days.count, connectionSessions: connections.count, events: events.count)
    }

    /// Recover a verified copy into a NEW directory only. Never replaces the
    /// active stores. The input manifest is pinned for the whole operation.
    /// A failed copy or verification leaves no published destination.
    public static func recoverCopy(from source: URL, to destination: URL) throws -> HistoryBundleSummary {
        guard source.isFileURL, destination.isFileURL,
              source.standardizedFileURL != destination.standardizedFileURL,
              !fm.fileExists(atPath: destination.path) else { throw fail() }
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let parentPath = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard parentPath != sourcePath, !parentPath.hasPrefix(sourcePath + "/") else { throw fail() }
        let manifestData = try read(source.appendingPathComponent("manifest.json"), max: 128 * 1024)
        let manifest = try JSONDecoder().decode(HistoryBundleManifest.self, from: manifestData)
        let expectedSummary = try inspect(source)
        guard try read(source.appendingPathComponent("manifest.json"), max: 128 * 1024) == manifestData,
              manifest.files == (try inventory(source, manifestPresent: true)) else { throw fail() }

        let temp = destination.deletingLastPathComponent().appendingPathComponent(".netguard-recovery-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        for folder in ["process-history", "connection-history", "event-history"] {
            try fm.createDirectory(at: temp.appendingPathComponent(folder), withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        // Derive paths from the validated inventory, never unchecked input.
        let entries = try inventory(source, manifestPresent: true)
        guard entries == manifest.files else { throw fail() }
        for entry in entries {
            let data = try read(source.appendingPathComponent(entry.path),
                max: entry.path == "history.sqlite" ? 64 * 1024 * 1024 : 2 * 1024 * 1024)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == entry.bytes, digest == entry.sha256 else { throw fail() }
            try write(data, to: temp.appendingPathComponent(entry.path))
        }
        try write(manifestData, to: temp.appendingPathComponent("manifest.json"))
        let summary = try inspect(temp)
        guard summary == expectedSummary else { throw fail() }
        try fm.moveItem(at: temp, to: destination)
        return summary
    }

}
