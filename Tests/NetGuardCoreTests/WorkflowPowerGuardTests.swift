import XCTest
@testable import NetGuardCore

final class WorkflowPowerGuardTests: XCTestCase {
    func testFocusPausesOptionalProbesButNotSampling() {
        var guardState = WorkflowPowerGuard()
        XCTAssertTrue(guardState.allowsOptionalProbes)
        guardState.setFocus(true)
        XCTAssertFalse(guardState.allowsOptionalProbes)
        XCTAssertTrue(guardState.allowsSampling)
        let generation = guardState.generation
        guardState.setFocus(true)
        XCTAssertEqual(guardState.generation, generation)
        guardState.setFocus(false)
        XCTAssertTrue(guardState.allowsOptionalProbes)
    }

    func testSleepWakeAndDuplicateEvents() {
        var guardState = WorkflowPowerGuard()
        guardState.setFocus(true)
        XCTAssertTrue(guardState.systemSleep())
        XCTAssertFalse(guardState.allowsSampling)
        let generation = guardState.generation
        XCTAssertFalse(guardState.systemSleep())
        XCTAssertEqual(guardState.generation, generation)
        XCTAssertTrue(guardState.systemWake())
        XCTAssertTrue(guardState.allowsSampling)
        XCTAssertFalse(guardState.allowsOptionalProbes)
        XCTAssertFalse(guardState.systemWake())
    }

    func testDisplaySleepDoesNotStopMonitoring() {
        var guardState = WorkflowPowerGuard()
        let generation = guardState.generation
        guardState.setDisplaySleeping(true)
        XCTAssertTrue(guardState.allowsSampling)
        XCTAssertTrue(guardState.allowsOptionalProbes)
        XCTAssertEqual(guardState.generation, generation)
        guardState.setDisplaySleeping(false)
        XCTAssertFalse(guardState.displaySleeping)
    }
}
