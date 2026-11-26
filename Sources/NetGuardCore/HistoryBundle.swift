import Foundation
import CryptoKit
import Darwin

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
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid() else { throw fail() }
    }

    private static func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw fail() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw fail() }
        try handle.close()
    }

    /// Sync each staged file and directory before publishing a single
    /// directory entry. The live stores are never opened for writing here.
    /// RENAME_EXCL makes destination existence a kernel-enforced condition.
    /// A failure after rename is an uncertain durability outcome: leave the
    /// complete published copy intact, never delete it or overwrite a target.
    private static func publish(_ staged: URL, to destination: URL,
                                version: Int, beforePublish: () throws -> Void) throws {
        try directory(staged)
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw fail() }
        defer { _ = close(parentFD) }
        let stageFD = openat(parentFD, staged.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw fail() }
        defer { _ = close(stageFD) }
        var stageInfo = stat()
        guard fstat(stageFD, &stageInfo) == 0, stageInfo.st_uid == geteuid(),
              (stageInfo.st_mode & 0o077) == 0 else { throw fail() }
        func syncFile(_ dir: Int32, _ name: String) throws {
            let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw fail() }
            defer { _ = close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid(), info.st_nlink == 1, fsync(fd) == 0 else { throw fail() }
        }
        try syncFile(stageFD, "history.sqlite")
        try syncFile(stageFD, "manifest.json")
        for folder in try folders(version: version) {
            let fd = openat(stageFD, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw fail() }
            defer { _ = close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
                  (info.st_mode & 0o077) == 0 else { throw fail() }
            for name in try fm.contentsOfDirectory(atPath: staged.appendingPathComponent(folder).path) {
                try syncFile(fd, name)
            }
            guard fsync(fd) == 0 else { throw fail() }
        }
        guard fsync(stageFD) == 0 else { throw fail() }
        try beforePublish()
        var current = stat()
        guard fstatat(parentFD, staged.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == stageInfo.st_dev, current.st_ino == stageInfo.st_ino,
              renameatx_np(parentFD, staged.lastPathComponent, parentFD,
                           destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw fail() }
        guard fsync(parentFD) == 0 else {
            throw HistoryStoreError.database("published history copy; directory durability uncertain")
        }
    }

    private static func read(_ url: URL, max: Int) throws -> Data {
        guard url.isFileURL, (1...64 * 1024 * 1024).contains(max),
              !url.lastPathComponent.isEmpty, url.lastPathComponent != ".", url.lastPathComponent != ".."
        else { throw fail() }
        // Open the parent and then the actual file, without following the
        // final directory/file symlinks or blocking on a FIFO. This validates
        // the opened inode rather than trusting a previous pathname stat.
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw fail() }
        defer { _ = close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw fail() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(fd, &initial) == 0,
              (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              initial.st_nlink == 1, initial.st_uid == geteuid(),
              initial.st_size >= 0, initial.st_size <= Int64(max)
        else { throw fail() }
        var data = Data()
        while data.count <= max {
            let chunk = try handle.read(upToCount: min(65_536, max + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        var final = stat()
        guard fstat(fd, &final) == 0, final.st_size == initial.st_size,
              final.st_nlink == 1, final.st_uid == geteuid(),
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              data.count <= max, Int64(data.count) == initial.st_size
        else { throw fail() }
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
        try publish(temp, to: destination, version: version, beforePublish: {})
        return result
    }

    /// Untrusted manifests cannot supply paths to read. Inventory is derived
    /// from the fixed directory layout, then compared to the manifest.
    public static func inspect(_ root: URL) throws -> HistoryBundleSummary {
        try directory(root)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifestData = try read(manifestURL, max: 256 * 1024)
        let manifest = try JSONDecoder().decode(HistoryBundleManifest.self, from: manifestData)
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
        // Reject a changed inventory after semantic reads. A copied bundle
        // is still independently verified before publication. No claim of
        // adversarial snapshot isolation from a same-user directory writer.
        guard try read(manifestURL, max: 256 * 1024) == manifestData,
              manifest.files == (try inventory(root, version: manifest.version, manifestPresent: true))
        else { throw fail() }
        return .init(version: manifest.version, database: database, agentDays: agentDays, processDays: days.count, connectionSessions: connections.count, events: events.count)
    }

    /// Recover a verified copy into a NEW directory only. Never replaces the
    /// active stores. The input manifest is pinned for the whole operation.
    /// A failed copy or verification leaves no published destination.
    /// If directory fsync fails after publication, the complete destination
    /// is preserved and the caller receives an uncertain-durability error.
    public static func recoverCopy(from source: URL, to destination: URL) throws -> HistoryBundleSummary {
        try recoverCopy(from: source, to: destination, beforePublish: {})
    }

    // Internal deterministic fault hook; no caller can use it to authorize
    // an active-store replacement, even in tests.
    static func recoverCopy(from source: URL, to destination: URL,
                            beforePublish: () throws -> Void) throws -> HistoryBundleSummary {
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
        try publish(temp, to: destination, version: manifest.version, beforePublish: beforePublish)
        return summary
    }

}
