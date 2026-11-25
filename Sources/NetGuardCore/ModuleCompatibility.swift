// The transitional flattened app build compiles the actual definitions directly.
// SwiftPM consumers retain the existing NetGuardCore spelling.
#if SWIFT_PACKAGE
import NetGuardObservation
import NetGuardWorkflow
import NetGuardRecovery
import NetGuardProvider
import NetGuardTraffic
import NetGuardData

public typealias NetworkQualityState = NetGuardObservation.NetworkQualityState
public typealias NetworkQualityWindow = NetGuardObservation.NetworkQualityWindow
public typealias ObservationSchedule = NetGuardObservation.ObservationSchedule
public typealias TunnelEvidence = NetGuardObservation.TunnelEvidence
public typealias LatencySummary = NetGuardObservation.LatencySummary
public typealias ThroughputPoint = NetGuardObservation.ThroughputPoint
public typealias ThroughputWindow = NetGuardObservation.ThroughputWindow
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
public typealias SampleQuality = NetGuardTraffic.SampleQuality
public typealias InterfaceCounters = NetGuardTraffic.InterfaceCounters
public typealias TrafficDelta = NetGuardTraffic.TrafficDelta
public typealias TrafficSnapshot = NetGuardTraffic.TrafficSnapshot
public typealias CounterAccumulator = NetGuardTraffic.CounterAccumulator
public typealias NetworkScope = NetGuardTraffic.NetworkScope
public typealias ScopedInterfaceSample = NetGuardTraffic.ScopedInterfaceSample
public typealias ScopedTrafficDelta = NetGuardTraffic.ScopedTrafficDelta
public typealias ScopedCounterAccumulator = NetGuardTraffic.ScopedCounterAccumulator
public typealias InterfaceScopeProjection = NetGuardTraffic.InterfaceScopeProjection
public typealias HistoryStoreError = NetGuardData.HistoryStoreError
public typealias HistoryDay = NetGuardData.HistoryDay
public typealias LegacyHistoryMigration = NetGuardData.LegacyHistoryMigration
public typealias ScopedHistoryDay = NetGuardData.ScopedHistoryDay
public typealias HistoryStore = NetGuardData.HistoryStore
public typealias HistoryPeriodDay = NetGuardData.HistoryPeriodDay
public typealias HistoryPeriod = NetGuardData.HistoryPeriod
public typealias HistoryAnalytics = NetGuardData.HistoryAnalytics
public typealias HistoryChartKind = NetGuardData.HistoryChartKind
public typealias HistoryChartPoint = NetGuardData.HistoryChartPoint
public typealias UsageMigrationError = NetGuardData.UsageMigrationError
public typealias DailyUsageState = NetGuardData.DailyUsageState
public typealias UsageMigration = NetGuardData.UsageMigration
public typealias HistoryBackupSummary = NetGuardData.HistoryBackupSummary
public typealias HistoryBackupInspector = NetGuardData.HistoryBackupInspector
#endif
