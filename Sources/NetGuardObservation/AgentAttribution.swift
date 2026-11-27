import Foundation

/// Local process-tree evidence; command paths are used transiently, never exported.
public struct ProcessTreeNode: Equatable, Sendable {
    public let pid: Int
    public let parent: Int
    public let start: String
    public let executable: String
}

public enum AgentAttribution {
    /// ps -ax -o pid=,ppid=,lstart=,comm=, with LC_ALL=C.
    /// Reject duplicate PIDs and unsupported rows. No argv or environment capture.
    public static func parseTree(_ output: String) -> [Int: ProcessTreeNode] {
        guard output.utf8.count <= 1_048_576 else { return [:] }
        var nodes: [Int: ProcessTreeNode] = [:]
        var duplicates = Set<Int>()
        var seen = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(maxSplits: 7, whereSeparator: \.isWhitespace)
            guard let first = f.first, let pid = Int(first), pid > 0 else { continue }
            if !seen.insert(pid).inserted { duplicates.insert(pid) }
            guard seen.count <= 8192 else { return [:] }
            guard f.count == 8, let parent = Int(f[1]), parent >= 0, parent != pid,
                  let start = ProcessStartEvidence.validate(Array(f[2...6])),
                  f[7].utf8.count <= 4096,
                  !f[7].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { continue }
            let executable = String(f[7]).trimmingCharacters(in: .whitespaces)
            guard !executable.isEmpty else { continue }
            let node = ProcessTreeNode(pid: pid, parent: parent,
                                       start: start, executable: executable)
            if nodes.updateValue(node, forKey: pid) != nil { duplicates.insert(pid) }
            if nodes.count > 8192 { return [:] }
        }
        for pid in duplicates { nodes.removeValue(forKey: pid) }
        return nodes
    }

    /// Exact executable basename hints, not verified bundle ID or code signature.
    private static func label(_ executable: String) -> String? {
        let name = (executable as NSString).lastPathComponent.lowercased()
        switch name {
        case "codex": return "Codex"
        case "chatgpt": return "ChatGPT"
        case "claude", "claude code": return "Claude / Claude Code"
        case "cursor": return "Cursor"
        case "ollama": return "Ollama"
        case "lm studio", "lmstudio": return "LM Studio"
        default: return nil
        }
    }

    private static func lineage(pid: Int, tree: [Int: ProcessTreeNode]) -> (String, [ProcessTreeNode])? {
        var current = pid
        var visited = Set<Int>()
        var chain: [ProcessTreeNode] = []
        for _ in 0..<32 {
            guard current > 0, visited.insert(current).inserted, let node = tree[current] else { return nil }
            chain.append(node)
            // Nearest recognized ancestor wins. A child contributes to one group only.
            if let workload = label(node.executable) {
                // Reject a visible cyclic ancestry, including a recognized root.
                var ancestor = node.parent
                var checked = visited
                for _ in 0..<32 {
                    guard ancestor > 0 else { return (workload, chain) }
                    guard checked.insert(ancestor).inserted else { return nil }
                    guard let parent = tree[ancestor] else { return (workload, chain) }
                    ancestor = parent.parent
                }
                return nil
            }
            current = node.parent
        }
        return nil
    }

    /// Require identical lineage around nettop. The synthetic identity also
    /// contains the complete matched lineage, so reparenting across samples
    /// breaks the delta baseline. Labels remain heuristic; no persistent paths.
    public static func attributed(_ counters: [ProcessCounter]?,
                                  before: [Int: ProcessTreeNode],
                                  after: [Int: ProcessTreeNode]) -> [ProcessCounter]? {
        guard let counters, counters.count <= 4096, !before.isEmpty, !after.isEmpty else { return nil }
        return counters.compactMap { row in
            guard before[row.pid]?.start == row.start, after[row.pid]?.start == row.start,
                  let a = lineage(pid: row.pid, tree: before),
                  let b = lineage(pid: row.pid, tree: after),
                  a.0 == b.0, a.1 == b.1 else { return nil }
            // Length-prefix variable data to avoid delimiter ambiguities.
            let identity = a.1.map { node in
                "\(node.pid):\(node.parent):\(node.start.utf8.count):\(node.start)\(node.executable.utf8.count):\(node.executable)"
            }.joined(separator: "|")
            return ProcessCounter(pid: row.pid, name: a.0, start: identity,
                                  received: row.received, sent: row.sent)
        }
    }
}
