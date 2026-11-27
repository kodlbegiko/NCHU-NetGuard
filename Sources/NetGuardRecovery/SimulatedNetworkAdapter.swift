import Foundation

/// Deterministic test-only adapter. Never invokes platform networking APIs.
public struct SimulatedNetworkAdapter: Sendable {
    public private(set) var configuration: OwnedNetworkConfiguration
    public private(set) var writes = 0

    public init(configuration: OwnedNetworkConfiguration) { self.configuration = configuration }

    public mutating func compareAndSwap(expected: OwnedNetworkConfiguration,
                                         desired: [String: String]) -> OwnedNetworkConfiguration? {
        guard configuration == expected, configuration.revision < UInt64.max,
              Set(desired.keys) == Set(expected.settings.keys) else { return nil }
        configuration = OwnedNetworkConfiguration(revision: configuration.revision + 1, settings: desired)
        writes += 1
        return configuration
    }

    public mutating func externalEdit(settings: [String: String]) {
        guard configuration.revision < UInt64.max else { return }
        configuration = OwnedNetworkConfiguration(revision: configuration.revision + 1, settings: settings)
    }
}


/// Faults affect only the in-memory simulated adapter or its fixture journal.
/// There is deliberately no host adapter, shell, or real authorization path.
public enum RecoverySimulationFault: String, CaseIterable, Hashable, Sendable {
    case preparedNotWritten, preparedUnknown, appliedNotWritten, appliedUnknown
    case committedNotWritten, committedUnknown, rolledBackNotWritten, rolledBackUnknown
    case applyUnknown, rollbackUnknown, externalBeforeApply, externalBeforeVerify
    case verificationUnavailable, rollbackVerificationUnavailable
}

public enum RecoverySimulationEvent: Equatable, Sendable {
    case persistence(RecoveryPhase, RecoveryPersistenceOutcome)
    case mutation(rollback: Bool, known: Bool)
    case verification(rollback: Bool, matches: Bool)
    case finish(RecoveryOutcome)
}

public struct RecoverySimulationResult: Equatable, Sendable {
    public let outcome: RecoveryOutcome
    public let configuration: OwnedNetworkConfiguration
    public let simulatedWrites: Int
    public let events: [RecoverySimulationEvent]
}

public enum RecoverySimulator {
    /// The authorization flag is intentionally a simulation input only.
    public static func execute(plan: RecoveryPlan, observed: OwnedNetworkConfiguration,
                               authorized: Bool, store: RecoveryJournalStore,
                               faults: Set<RecoverySimulationFault> = []) -> RecoverySimulationResult {
        var transaction = RecoveryTransaction()
        let initial = transaction.begin(plan, observed: observed, authorized: authorized)
        return drive(transaction: transaction, initial: initial, plan: plan, observed: observed,
                     store: store, faults: faults)
    }

    /// A fixture crash restart reads the same on-disk journal. Invalid or
    /// absent evidence stops without any simulated mutation.
    public static func restart(observed: OwnedNetworkConfiguration, store: RecoveryJournalStore,
                               faults: Set<RecoverySimulationFault> = []) -> RecoverySimulationResult {
        do {
            guard let entry = try store.load() else { return failed(observed) }
            var transaction = RecoveryTransaction()
            let initial = transaction.recover(entry, observed: observed)
            return drive(transaction: transaction, initial: initial, plan: entry.plan, observed: observed,
                         store: store, faults: faults)
        } catch { return failed(observed) }
    }

    private static func failed(_ observed: OwnedNetworkConfiguration) -> RecoverySimulationResult {
        .init(outcome: .safeMode, configuration: observed, simulatedWrites: 0, events: [.finish(.safeMode)])
    }

    private static func persistence(_ entry: RecoveryJournalEntry, store: RecoveryJournalStore,
                                    faults: Set<RecoverySimulationFault>) -> RecoveryPersistenceOutcome {
        let before: RecoverySimulationFault?
        let ambiguous: RecoverySimulationFault?
        switch entry.phase {
        case .prepared: before = .preparedNotWritten; ambiguous = .preparedUnknown
        case .applied: before = .appliedNotWritten; ambiguous = .appliedUnknown
        case .committed: before = .committedNotWritten; ambiguous = .committedUnknown
        case .rolledBack: before = .rolledBackNotWritten; ambiguous = .rolledBackUnknown
        case .safeMode: before = nil; ambiguous = nil
        }
        if let before, faults.contains(before) { return .notWritten }
        do {
            if entry.phase == .prepared {
                try store.prepareNew(entry)
            } else {
                try store.save(entry)
            }
            if let ambiguous, faults.contains(ambiguous) { return .unknown }
            return .persisted
        } catch JournalValidationError.writeOutcomeUnknown {
            return .unknown
        } catch {
            return .notWritten
        }
    }

    private static func drive(transaction initialTransaction: RecoveryTransaction, initial: RecoveryEffect,
                              plan: RecoveryPlan, observed: OwnedNetworkConfiguration,
                              store: RecoveryJournalStore, faults: Set<RecoverySimulationFault>) -> RecoverySimulationResult {
        var transaction = initialTransaction
        var adapter = SimulatedNetworkAdapter(configuration: observed)
        var effect = initial
        var events: [RecoverySimulationEvent] = []
        func finish(_ result: RecoveryOutcome) -> RecoverySimulationResult {
            .init(outcome: result, configuration: adapter.configuration,
                  simulatedWrites: adapter.writes, events: events + [.finish(result)])
        }
        // Bound effects even if a future state-machine regression introduces a loop.
        for _ in 0..<16 {
            switch effect {
            case .finish(let result): return finish(result)
            case .persist(let entry):
                let result = persistence(entry, store: store, faults: faults)
                events.append(.persistence(entry.phase, result))
                effect = transaction.persisted(result)
            case .compareAndSwap(let expected, let desired):
                let rollback = desired == plan.expected.settings
                if !rollback, faults.contains(.externalBeforeApply) {
                    adapter.externalEdit(settings: adapter.configuration.settings)
                }
                var result = adapter.compareAndSwap(expected: expected, desired: desired)
                if faults.contains(rollback ? .rollbackUnknown : .applyUnknown) { result = nil }
                events.append(.mutation(rollback: rollback, known: result != nil))
                effect = transaction.mutationResult(result)
            case .verify(let expected):
                let rollback = expected.settings == plan.expected.settings
                if !rollback, faults.contains(.externalBeforeVerify) {
                    adapter.externalEdit(settings: adapter.configuration.settings)
                }
                let unavailable = faults.contains(rollback ? .rollbackVerificationUnavailable : .verificationUnavailable)
                let result = unavailable ? nil : adapter.configuration
                events.append(.verification(rollback: rollback, matches: result == expected))
                effect = transaction.verified(result)
            }
        }
        return finish(.safeMode)
    }
}
