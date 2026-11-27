import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum JournalValidationError: Error, Equatable {
    case invalidVersion, invalidPlan, invalidPhase, conflict, oversized, lockBusy, ioFailure, writeOutcomeUnknown
}

/// Validate persisted data before it can be passed to the recovery state machine.
public extension RecoveryJournalEntry {
    func validate() throws {
        guard schemaVersion == 1 else { throw JournalValidationError.invalidVersion }
        let keys = plan.expected.settings.keys
        guard !keys.isEmpty, keys.count <= 256,
              keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 &&
                  !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              plan.expected.settings.values.allSatisfy({ $0.utf8.count <= 4096 }),
              plan.desired.values.allSatisfy({ $0.utf8.count <= 4096 }),
              Set(keys) == Set(plan.desired.keys),
              plan.expected.settings != plan.desired,
              plan.expected.revision < UInt64.max else { throw JournalValidationError.invalidPlan }
        if let applied {
            guard applied.revision > plan.expected.revision,
                  applied.settings == plan.desired else { throw JournalValidationError.invalidPhase }
        }
        if let restored {
            guard phase == .rolledBack, let applied,
                  restored.revision > applied.revision,
                  restored.settings == plan.expected.settings else { throw JournalValidationError.invalidPhase }
        }
        switch phase {
        case .prepared:
            guard applied == nil else { throw JournalValidationError.invalidPhase }
        case .applied, .committed, .rolledBack:
            guard applied != nil else { throw JournalValidationError.invalidPhase }
        case .safeMode:
            break
        }
    }
}

/// Descriptor-relative, cooperating-writer journal with nonblocking advisory lock.
/// Regular single-link files only; file fsync before rename and directory fsync
/// after rename. This is not a promise of hardware durability or protection
/// against arbitrary non-cooperating processes. Real host adapter stays disabled.
public struct RecoveryJournalStore: Sendable {
    public let url: URL
    private let limit = 1_048_576
    public init(url: URL) { self.url = url }

    private func withLock<T>(_ body: (Int32, String) throws -> T) throws -> T {
        guard url.isFileURL, !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".", url.lastPathComponent != ".." else {
            throw JournalValidationError.invalidPlan
        }
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw JournalValidationError.ioFailure }
        defer { _ = close(parent) }
        var directoryInfo = stat()
        guard fstat(parent, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & 0o022 == 0 else {
            throw JournalValidationError.invalidPlan
        }
        let lock = openat(parent, name + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard lock >= 0 else { throw JournalValidationError.ioFailure }
        defer { _ = close(lock) }
        try validateRegular(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw JournalValidationError.lockBusy }
        defer { _ = flock(lock, LOCK_UN) }
        return try body(parent, name)
    }

    private func validateRegular(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw JournalValidationError.invalidPlan
        }
    }

    private func readLocked(parent: Int32, name: String) throws -> RecoveryJournalEntry? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw JournalValidationError.ioFailure
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try validateRegular(fd)
        var data = Data()
        while data.count <= limit {
            let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw JournalValidationError.oversized }
        let entry = try JSONDecoder().decode(RecoveryJournalEntry.self, from: data)
        try entry.validate()
        return entry
    }

    public func load() throws -> RecoveryJournalEntry? {
        try withLock { parent, name in try readLocked(parent: parent, name: name) }
    }

    public func save(_ entry: RecoveryJournalEntry) throws {
        try write(entry, requireAbsent: false)
    }

    // A new simulated transaction must never reuse a prior prepared record.
    // The absence check shares the same lock as journal publication.
    func prepareNew(_ entry: RecoveryJournalEntry) throws {
        guard entry.phase == .prepared else { throw JournalValidationError.invalidPhase }
        try write(entry, requireAbsent: true)
    }

    private func write(_ entry: RecoveryJournalEntry, requireAbsent: Bool) throws {
        try entry.validate()
        // Legacy journals without the additive restoration evidence remain
        // readable. New rolledBack records must prove the exact observation.
        guard entry.phase != .rolledBack || entry.restored != nil else {
            throw JournalValidationError.invalidPhase
        }
        try withLock { parent, name in
            if let existing = try readLocked(parent: parent, name: name) {
                guard !requireAbsent, existing.plan == entry.plan else { throw JournalValidationError.conflict }
                if existing == entry { return }
                let allowed: Bool
                switch (existing.phase, entry.phase) {
                case (.prepared, .applied), (.applied, .committed),
                     (.applied, .rolledBack), (.prepared, .rolledBack),
                     (.prepared, .safeMode), (.applied, .safeMode):
                    allowed = true
                default:
                    allowed = false
                }
                guard allowed, existing.applied == nil || existing.applied == entry.applied
                else { throw JournalValidationError.conflict }
            } else {
                guard entry.phase == .prepared else { throw JournalValidationError.conflict }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entry)
            guard data.count <= limit else { throw JournalValidationError.oversized }
            let temporary = ".netguard-journal-" + UUID().uuidString
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw JournalValidationError.ioFailure }
            defer { _ = unlinkat(parent, temporary, 0) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0 else { throw JournalValidationError.ioFailure }
            try handle.close()
            guard renameat(parent, temporary, parent, name) == 0 else {
                throw JournalValidationError.writeOutcomeUnknown
            }
            // Once renamed, a sync failure cannot prove that the write did not happen.
            guard fsync(parent) == 0 else { throw JournalValidationError.writeOutcomeUnknown }
        }
    }
}
