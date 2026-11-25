import XCTest
import NetGuardObservation

final class AgentAttributionTests: XCTestCase {
    private let date = "Wed Nov 25 12:00:00 2026"
    private func tree(_ rows: [(Int, Int, String)]) -> [Int: ProcessTreeNode] {
        AgentAttribution.parseTree(rows.map { "\($0.0) \($0.1) \(date) \($0.2)" }.joined(separator: "\n"))
    }
    private func counter(_ pid: Int, _ bytes: UInt64, sent: UInt64 = 0) -> ProcessCounter {
        .init(pid: pid, name: "worker", start: date, received: bytes, sent: sent)
    }

    func testNearestRecognizedAncestorAndExactNames() throws {
        let t = tree([(10, 1, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
                      (20, 10, "/opt/bin/codex"), (21, 20, "/bin/node"),
                      (22, 10, "/bin/helper"), (30, 1, "/tmp/not-codex")])
        let rows = try XCTUnwrap(AgentAttribution.attributed([counter(21, 5), counter(22, 10), counter(30, 20)], before: t, after: t))
        XCTAssertEqual(rows.map(\.name), ["Codex", "Cursor"])
    }

    func testChangedParentOrMissingAncestorIsNotAttributed() throws {
        let a = tree([(10, 1, "codex"), (20, 10, "node")])
        let b = tree([(10, 1, "codex"), (20, 1, "node")])
        XCTAssertEqual(AgentAttribution.attributed([counter(20, 5)], before: a, after: b), [])
        XCTAssertEqual(AgentAttribution.attributed([counter(20, 5)], before: b, after: b), [])
        XCTAssertNil(AgentAttribution.attributed(nil, before: a, after: a))
    }

    func testDuplicatePIDAndCyclesFailClosed() {
        let t = tree([(10, 1, "codex"), (10, 1, "ollama"), (20, 10, "node"),
                      (30, 31, "node"), (31, 30, "node")])
        XCTAssertNil(t[10])
        XCTAssertEqual(AgentAttribution.attributed([counter(20, 5), counter(30, 9)], before: t, after: t), [])
    }

    func testMalformedDuplicateAndRecognizedCycleRejected() {
        let a = AgentAttribution.parseTree("10 1 Wed Nov 25 12:00:00 2026 codex\n10 1 malformed")
        XCTAssertNil(a[10])
        let cycle = tree([(10, 20, "codex"), (20, 10, "worker")])
        XCTAssertEqual(AgentAttribution.attributed([counter(20, 5)], before: cycle, after: cycle), [])
    }
    func testChatGPTLabelIsOnlyObservedHint() throws {
        let t = tree([(10, 1, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"), (20, 10, "worker")])
        XCTAssertEqual(AgentAttribution.attributed([counter(20, 5)], before: t, after: t)?.first?.name, "ChatGPT")
    }
    func testReparentingBreaksDeltaAndStableChildrenAggregateOnce() throws {
        let a = tree([(10, 1, "codex"), (20, 10, "node"), (21, 10, "worker")])
        let b = tree([(11, 1, "codex"), (20, 11, "node"), (21, 11, "worker")])
        var engine = ProcessUsageAccumulator()
        engine.ingest(AgentAttribution.attributed([counter(20, 100), counter(21, 200)], before: a, after: a), uptime: 1)
        engine.ingest(AgentAttribution.attributed([counter(20, 110), counter(21, 230)], before: a, after: a), uptime: 2)
        XCTAssertEqual(engine.report().rows.first?.received, 40)
        engine.ingest(AgentAttribution.attributed([counter(20, 500), counter(21, 600)], before: b, after: b), uptime: 3)
        XCTAssertEqual(engine.report().rows.first?.received, 40)
        engine.ingest(AgentAttribution.attributed([counter(20, 510, sent: 5), counter(21, 620)], before: b, after: b), uptime: 4)
        XCTAssertEqual(engine.report().rows.first?.received, 70)
        XCTAssertEqual(engine.report().rows.first?.sent, 5)
    }
}
