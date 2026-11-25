// The transitional flattened app build compiles the actual definitions directly.
// SwiftPM consumers retain the existing NetGuardCore spelling.
#if SWIFT_PACKAGE
import NetGuardObservation
import NetGuardWorkflow
import NetGuardRecovery
import NetGuardProvider

public typealias NetworkQualityState = NetGuardObservation.NetworkQualityState
public typealias NetworkQualityWindow = NetGuardObservation.NetworkQualityWindow
public typealias AppTrafficObservation = NetGuardObservation.AppTrafficObservation
public typealias AppTrafficParser = NetGuardObservation.AppTrafficParser
public typealias WorkflowPowerGuard = NetGuardWorkflow.WorkflowPowerGuard
public typealias OwnedNetworkConfiguration = NetGuardRecovery.OwnedNetworkConfiguration
public typealias RecoveryPlan = NetGuardRecovery.RecoveryPlan
public typealias RecoveryPhase = NetGuardRecovery.RecoveryPhase
public typealias RecoveryJournalEntry = NetGuardRecovery.RecoveryJournalEntry
public typealias RecoveryOutcome = NetGuardRecovery.RecoveryOutcome
public typealias RecoveryEffect = NetGuardRecovery.RecoveryEffect
public typealias RecoveryTransaction = NetGuardRecovery.RecoveryTransaction
public typealias JournalValidationError = NetGuardRecovery.JournalValidationError
public typealias RecoveryJournalStore = NetGuardRecovery.RecoveryJournalStore
public typealias SimulatedNetworkAdapter = NetGuardRecovery.SimulatedNetworkAdapter
public typealias ProviderStatus = NetGuardProvider.ProviderStatus
public typealias ProviderObservation = NetGuardProvider.ProviderObservation
#endif
