import Foundation
import XCTest
import NetGuardCore

final class ObservationRuleTests: XCTestCase {
    func testUnknownHigherPriorityBlocksLowerRule() {
        let high = ObservationRule(priority: 10, minimumQuotaTier: .high, action: .notify)
        let low = ObservationRule(priority: 1, connected: true, action: .observe)
        let set = ObservationRuleSet(rules: [low, high])
        XCTAssertEqual(ObservationRuleEngine.preview(set, input: .init(scope: nil, quotaTier: nil,
            connected: true, focusEnabled: nil)).status, .unknown)
        XCTAssertEqual(ObservationRuleEngine.preview(set, input: .init(scope: nil, quotaTier: .normal,
            connected: true, focusEnabled: nil)).action, .observe)
    }
    func testConflictingEqualPriorityRulesDoNotChooseArbitrarily() {
        let first = ObservationRule(priority: 10, connected: true, action: .notify)
        let second = ObservationRule(priority: 10, focusEnabled: true, action: .deferAction)
        let result = ObservationRuleEngine.preview(.init(rules: [first, second]),
            input: .init(scope: nil, quotaTier: nil, connected: true, focusEnabled: true))
        XCTAssertEqual(result.status, .conflict)
        XCTAssertNil(result.action)
        XCTAssertEqual(Set(result.ruleIDs), Set([first.id, second.id]))
    }
    func testFalseConditionDominatesUnknownAndInvalidRulesRejected() throws {
        let rule = ObservationRule(priority: 10, scope: .dorm, connected: true, action: .notify)
        let set = ObservationRuleSet(rules: [rule])
        XCTAssertEqual(ObservationRuleEngine.preview(set, input: .init(scope: nil, quotaTier: nil,
            connected: false, focusEnabled: nil)).status, .noMatch)
        XCTAssertEqual(try ObservationRuleSet.decode(JSONEncoder().encode(set)), set)
        XCTAssertThrowsError(try ObservationRuleSet(rules: [rule, rule]).validate())
        XCTAssertThrowsError(try ObservationRuleSet(rules: [.init(priority: 1, action: .notify)]).validate())
        XCTAssertThrowsError(try ObservationRuleSet.decode(Data(repeating: 32, count: 65_537)))
    }
}
