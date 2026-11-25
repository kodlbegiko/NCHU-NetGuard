import XCTest
import NetGuardWorkflow

final class WorkflowModuleTests: XCTestCase {
    func testStandaloneWorkflow() {
        var workflow = WorkflowPowerGuard()
        workflow.setFocus(true)
        XCTAssertTrue(workflow.allowsSampling)
        XCTAssertFalse(workflow.allowsOptionalProbes)
        XCTAssertTrue(workflow.systemSleep())
        XCTAssertFalse(workflow.allowsSampling)
    }
}
