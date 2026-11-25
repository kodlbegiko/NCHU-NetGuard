import Foundation

/// Snapshot of only the configuration owned by a future authorized adapter.
/// Revision must be monotonically increasing, including external writes.
public struct OwnedNetworkConfiguration: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let settings: [String: String]
    public init(revision: UInt64, settings: [String: String]) {
        self.revision = revision
        self.settings = settings
    }
}

public struct RecoveryPlan: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let expected: OwnedNetworkConfiguration
    public let desired: [String: String]
    public init(transactionID: UUID, expected: OwnedNetworkConfiguration, desired: [String: String]) {
        self.transactionID = transactionID
        self.expected = expected
        self.desired = desired
    }
}

public enum RecoveryPhase: String, Codable, Sendable {
    case prepared, applied, committed, rolledBack, safeMode
}

public struct RecoveryJournalEntry: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let plan: RecoveryPlan
    public var phase: RecoveryPhase
    public var applied: OwnedNetworkConfiguration?
    /// Optional additive v1 field. Old rolledBack entries without this
    /// evidence remain readable but cannot prove a current rollback.
    public var restored: OwnedNetworkConfiguration?
    public init(plan: RecoveryPlan) {
        self.schemaVersion = 1
        self.plan = plan
        self.phase = .prepared
        self.applied = nil
        self.restored = nil
    }
}

/// Persistence callbacks must distinguish a proven pre-write failure from an
/// ambiguous result (for example, rename succeeded but directory sync failed).
public enum RecoveryPersistenceOutcome: Equatable, Sendable {
    case persisted, notWritten, unknown
}

public enum RecoveryOutcome: Equatable, Sendable {
    case rejected, committed, rolledBack, safeMode
}

/// Pure state machine: no host commands, privilege grants, or system adapter.
/// A caller may execute returned effects only in a simulated or separately
/// approved transactional adapter. Persist each journal before executing effects.
public enum RecoveryEffect: Equatable, Sendable {
    case persist(RecoveryJournalEntry)
    case compareAndSwap(expected: OwnedNetworkConfiguration, desired: [String: String])
    case verify(OwnedNetworkConfiguration)
    case finish(RecoveryOutcome)
}

public struct RecoveryTransaction: Sendable {
    private enum Step: Sendable {
        case idle, preparing, applying, recordingApplied, verifying,
             committing, restoring, verifyingRestore, recordingRestore, terminal
    }
    private var step: Step = .idle
    private var journal: RecoveryJournalEntry?
    private var restored: OwnedNetworkConfiguration?

    public init() {}

    public mutating func begin(_ plan: RecoveryPlan, observed: OwnedNetworkConfiguration,
                               authorized: Bool) -> RecoveryEffect {
        guard step == .idle else { return .finish(.rejected) }
        guard authorized, observed == plan.expected, observed.revision < UInt64.max,
              !plan.expected.settings.isEmpty,
              Set(plan.expected.settings.keys) == Set(plan.desired.keys),
              plan.desired != plan.expected.settings else {
            return .finish(.rejected)
        }
        let entry = RecoveryJournalEntry(plan: plan)
        guard (try? entry.validate()) != nil else { return .finish(.rejected) }
        journal = entry
        step = .preparing
        return .persist(entry)
    }

    public mutating func persisted(success: Bool) -> RecoveryEffect {
        persisted(success ? .persisted : .unknown)
    }

    public mutating func persisted(_ outcome: RecoveryPersistenceOutcome) -> RecoveryEffect {
        guard let entry = journal else { return terminal(.safeMode) }
        let success = outcome == .persisted
        switch step {
        case .preparing:
            guard success else { return terminal(.rejected) }
            step = .applying
            return .compareAndSwap(expected: entry.plan.expected, desired: entry.plan.desired)
        case .recordingApplied:
            guard let applied = entry.applied else { return terminal(.safeMode) }
            if !success {
                guard outcome == .notWritten else { return terminal(.safeMode) }
                step = .restoring
                return .compareAndSwap(expected: applied, desired: entry.plan.expected.settings)
            }
            step = .verifying
            return .verify(applied)
        case .committing:
            if success { return terminal(.committed) }
            guard outcome == .notWritten, let applied = entry.applied else { return terminal(.safeMode) }
            step = .restoring
            return .compareAndSwap(expected: applied, desired: entry.plan.expected.settings)
        case .recordingRestore:
            return terminal(success ? .rolledBack : .safeMode)
        default:
            return terminal(.safeMode)
        }
    }

    /// A nil result means the mutation's outcome is unknown, not definitely unchanged.
    public mutating func mutationResult(_ result: OwnedNetworkConfiguration?) -> RecoveryEffect {
        guard var entry = journal, let result else { return terminal(.safeMode) }
        switch step {
        case .applying:
            guard result.revision > entry.plan.expected.revision,
                  result.settings == entry.plan.desired else { return terminal(.safeMode) }
            entry.applied = result
            entry.phase = .applied
            journal = entry
            step = .recordingApplied
            return .persist(entry)
        case .restoring:
            guard let applied = entry.applied, result.revision > applied.revision,
                  result.settings == entry.plan.expected.settings else { return terminal(.safeMode) }
            restored = result
            step = .verifyingRestore
            return .verify(result)
        default:
            return terminal(.safeMode)
        }
    }

    public mutating func verified(_ observed: OwnedNetworkConfiguration?) -> RecoveryEffect {
        guard var entry = journal else { return terminal(.safeMode) }
        switch step {
        case .verifying:
            guard let applied = entry.applied else { return terminal(.safeMode) }
            if observed == applied {
                entry.phase = .committed
                journal = entry
                step = .committing
                return .persist(entry)
            }
            // Exact compare-and-swap prevents overwriting an intervening external edit.
            step = .restoring
            return .compareAndSwap(expected: applied, desired: entry.plan.expected.settings)
        case .verifyingRestore:
            guard let restored, observed == restored else { return terminal(.safeMode) }
            entry.phase = .rolledBack
            entry.restored = restored
            journal = entry
            step = .recordingRestore
            return .persist(entry)
        default:
            return terminal(.safeMode)
        }
    }

    /// Recovery after a crash deliberately refuses to infer mutation ownership.
    /// A prepared journal may have crashed before or after a write. An applied
    /// journal permits rollback only if the current revision and settings match.
    public mutating func recover(_ entry: RecoveryJournalEntry,
                                 observed: OwnedNetworkConfiguration) -> RecoveryEffect {
        guard step == .idle, (try? entry.validate()) != nil else { return terminal(.safeMode) }
        journal = entry
        switch entry.phase {
        case .prepared:
            return terminal(observed == entry.plan.expected ? .rejected : .safeMode)
        case .applied:
            guard let applied = entry.applied,
                  applied.revision > entry.plan.expected.revision,
                  applied.settings == entry.plan.desired,
                  observed == applied else { return terminal(.safeMode) }
            step = .restoring
            return .compareAndSwap(expected: applied, desired: entry.plan.expected.settings)
        case .committed:
            return terminal(observed == entry.applied ? .committed : .safeMode)
        case .rolledBack:
            guard let restored = entry.restored, observed == restored else { return terminal(.safeMode) }
            return terminal(.rolledBack)
        case .safeMode:
            return terminal(.safeMode)
        }
    }

    private mutating func terminal(_ result: RecoveryOutcome) -> RecoveryEffect {
        step = .terminal
        return .finish(result)
    }
}
