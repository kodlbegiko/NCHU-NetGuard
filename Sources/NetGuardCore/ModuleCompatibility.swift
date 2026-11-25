// The transitional flattened app build compiles the actual definitions directly.
// SwiftPM consumers retain the existing NetGuardCore spelling.
#if SWIFT_PACKAGE
import NetGuardObservation
import NetGuardWorkflow

public typealias NetworkQualityState = NetGuardObservation.NetworkQualityState
public typealias NetworkQualityWindow = NetGuardObservation.NetworkQualityWindow
public typealias AppTrafficObservation = NetGuardObservation.AppTrafficObservation
public typealias AppTrafficParser = NetGuardObservation.AppTrafficParser
public typealias WorkflowPowerGuard = NetGuardWorkflow.WorkflowPowerGuard
#endif
