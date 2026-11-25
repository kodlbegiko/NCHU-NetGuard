import Foundation
import CryptoKit

public struct HistoryBundleSummary: Equatable, Sendable {
    public let version: Int
    public let database: HistoryBackupSummary
    /// nil means the older V1 format does not include AI history.
    public let agentDays: Int?
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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= max {
            let chunk = try handle.read(upToCount: min(65_536, max + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= max else { throw fail() }
        return data
    }

    private static func folders(version: Int) throws -> [String] {
        guard [1, 2].contains(version) else { throw fail() }
        return ["process-history", "connection-history", "event-history"] + (version == 2 ? ["agent-history"] : [])
    }

    private static func inventory(_ root: URL, version: Int, manifestPresent: Bool) throws -> [HistoryBundleManifest.Entry] {
        try directory(root)
        let expected = Set(["history.sqlite"] + (try folders(version: version)) + (manifestPresent ? ["manifest.json"] : []))
        guard Set(try fm.contentsOfDirectory(atPath: root.path)) == expected else { throw fail() }
        for (folder, expectedFile) in [("connection-history", "sessions.json"), ("event-history", "events.json")] {
            let url = root.appendingPathComponent(folder)
            try directory(url)
            guard try fm.contentsOfDirectory(atPath: url.path) == [expectedFile] else { throw fail() }
        }
        var paths = fixed
        for folder in ["process-history"] + (version == 2 ? ["agent-history"] : []) {
            let url = root.appendingPathComponent(folder)
            try directory(url)
            let names = try fm.contentsOfDirectory(atPath: url.path)
            guard names.count <= 366 else { throw fail() }
            for name in names {
                guard name.hasSuffix(".json") else { throw fail() }
                _ = try HistoryDay(day: String(name.dropLast(5)), total: 0, download: nil, upload: nil)
                paths.append(folder + "/" + name)
            }
        }
        var total = 0
        return try paths.sorted().map { path in
            let data = try read(root.appendingPathComponent(path), max: path == "history.sqlite" ? 64 * 1024 * 1024 : 2 * 1024 * 1024)
            total += data.count
            guard total <= maxTotal else { throw fail() }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return .init(path: path, bytes: data.count, sha256: hash)
        }
    }

    public static func create(database: URL, process: ProcessHistoryStore,
                              connections: ConnectionHistoryStore, events: TrafficEventArchive,
                              agents: AgentHistoryStore? = nil,
                              destination: URL) throws -> HistoryBundleSummary {
        guard destination.isFileURL, !fm.fileExists(atPath: destination.path) else { throw fail() }
        let version = agents == nil ? 1 : 2
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".netguard-history-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        for folder in try folders(version: version) {
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
        if let agents {
            let agentDays = try agents.storedDays()
            guard agentDays.count <= 366 else { throw fail() }
            for day in agentDays {
                let data = try encoder.encode(agents.read(day: day).buckets)
                processBytes += data.count
                guard data.count <= 2 * 1024 * 1024, processBytes <= maxTotal else { throw fail() }
                try write(data, to: temp.appendingPathComponent("agent-history/\(day).json"))
            }
        }
        try write(encoder.encode(connections.read()), to: temp.appendingPathComponent("connection-history/sessions.json"))
        try write(encoder.encode(events.read()), to: temp.appendingPathComponent("event-history/events.json"))
        let entries = try inventory(temp, version: version, manifestPresent: false)
        let manifest = HistoryBundleManifest(version: version, createdAt: Date(), files: entries)
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
            from: read(root.appendingPathComponent("manifest.json"), max: 256 * 1024))
        guard [1, 2].contains(manifest.version), manifest.createdAt.timeIntervalSince1970.isFinite,
              manifest.files.count <= (manifest.version == 1 ? 369 : 735),
              manifest.files == (try inventory(root, version: manifest.version, manifestPresent: true)) else { throw fail() }
        let database = try HistoryBackupInspector.inspect(root.appendingPathComponent("history.sqlite"))
        let process = ProcessHistoryStore(directory: root.appendingPathComponent("process-history"))
        let days = try process.storedDays()
        for day in days { _ = try process.read(day: day) }
        let agentDays: Int?
        if manifest.version == 2 {
            let agents = AgentHistoryStore(directory: root.appendingPathComponent("agent-history"))
            let dates = try agents.storedDays()
            for day in dates { _ = try agents.read(day: day) }
            agentDays = dates.count
        } else { agentDays = nil }
        let connections = try ConnectionHistoryStore(directory: root.appendingPathComponent("connection-history")).read()
        let events = try TrafficEventArchive(directory: root.appendingPathComponent("event-history")).read()
        return .init(version: manifest.version, database: database, agentDays: agentDays, processDays: days.count, connectionSessions: connections.count, events: events.count)
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
        let manifestData = try read(source.appendingPathComponent("manifest.json"), max: 256 * 1024)
        let manifest = try JSONDecoder().decode(HistoryBundleManifest.self, from: manifestData)
        let expectedSummary = try inspect(source)
        guard try read(source.appendingPathComponent("manifest.json"), max: 256 * 1024) == manifestData,
              manifest.files == (try inventory(source, version: manifest.version, manifestPresent: true)) else { throw fail() }

        let temp = destination.deletingLastPathComponent().appendingPathComponent(".netguard-recovery-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        for folder in try folders(version: manifest.version) {
            try fm.createDirectory(at: temp.appendingPathComponent(folder), withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        // Derive paths from the validated inventory, never unchecked input.
        let entries = try inventory(source, version: manifest.version, manifestPresent: true)
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
