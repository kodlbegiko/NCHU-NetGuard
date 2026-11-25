import Foundation

public enum JournalValidationError: Error, Equatable {
    case invalidVersion, invalidPlan, invalidPhase, conflict, oversized
}

/// Validate persisted data before it can be passed to the recovery state machine.
public extension RecoveryJournalEntry {
    func validate() throws {
        guard schemaVersion == 1 else { throw JournalValidationError.invalidVersion }
        guard !plan.expected.settings.isEmpty,
              Set(plan.expected.settings.keys) == Set(plan.desired.keys),
              plan.expected.settings != plan.desired,
              plan.expected.revision < UInt64.max else { throw JournalValidationError.invalidPlan }
        if let applied {
            guard applied.revision > plan.expected.revision,
                  applied.settings == plan.desired else { throw JournalValidationError.invalidPhase }
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

/// Atomic file replacement, for one local journal writer only. Does not promise
/// fsync durability or multi-process exclusion; real host adapter remains disabled.
public struct RecoveryJournalStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> RecoveryJournalEntry? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Enforce the byte ceiling while reading, before decoding. Checking
        // Data.count after loading the entire file does not bound resource use.
        let limit = 1_048_576
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= limit {
            let remaining = limit + 1 - data.count
            let chunk = try handle.read(upToCount: min(65_536, remaining)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw JournalValidationError.oversized }
        let entry = try JSONDecoder().decode(RecoveryJournalEntry.self, from: data)
        try entry.validate()
        return entry
    }

    public func save(_ entry: RecoveryJournalEntry) throws {
        try entry.validate()
        if let existing = try load() {
            guard existing.plan == entry.plan else { throw JournalValidationError.conflict }
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
            guard allowed else { throw JournalValidationError.conflict }
        } else {
            guard entry.phase == .prepared else { throw JournalValidationError.conflict }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        guard data.count <= 1_048_576 else { throw JournalValidationError.oversized }
        try data.write(to: url, options: [.atomic])
    }
}
