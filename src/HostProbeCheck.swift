import Foundation

/// The local compatibility check emits only coarse outcome categories.
/// No network requests, raw command output, PIDs, paths, addresses or names.
enum HostProbeCheck {
    enum Result: String {
        case compatible, unavailable, incompatible, insufficient
    }

    static func run() -> Int32 {
        let before = tree()
        let nettop = ProbeRunner.run("/usr/bin/nettop", ["-P", "-L", "1", "-J", "bytes_in,bytes_out"], timeout: 5)
        let after = tree()
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        let ps: Result
        if let before, let after {
            if let a = before[selfPID], let b = after[selfPID], a == b {
                ps = .compatible
            } else { ps = .incompatible }
        } else { ps = .unavailable }

        let counters: Result
        switch nettop {
        case .success(let raw):
            if let before, let after, ps == .compatible {
                if let rows = ProcessCounterParser.parse(raw, before: before.mapValues { $0.start }, after: after.mapValues { $0.start }) {
                    counters = rows.isEmpty ? .insufficient : .compatible
                } else { counters = .incompatible }
            } else { counters = .insufficient }
        default: counters = .unavailable
        }
        let v4 = route(ipv6: false)
        let v6 = route(ipv6: true)
        print("NETGUARD_HOST_CHECK_V1")
        print("ps=\(ps.rawValue)")
        print("nettop=\(counters.rawValue)")
        print("ipv4_default_route=\(v4.rawValue)")
        print("ipv6_default_route=\(v6.rawValue)")
        // A missing route is not a parser failure, and a zero-row snapshot
        // is not affirmative process-counter compatibility.
        guard ps == .compatible, counters == .compatible,
              v4 != .incompatible, v6 != .incompatible,
              v4 == .compatible || v6 == .compatible else {
            print("NETGUARD_HOST_CHECK_INCONCLUSIVE")
            return 2
        }
        print("NETGUARD_HOST_CHECK_OK")
        return 0
    }

    private static func tree() -> [Int: ProcessTreeNode]? {
        guard case .success(let raw) = ProbeRunner.run("/bin/ps",
            ["-ax", "-o", "pid=,ppid=,lstart=,comm="], timeout: 2) else { return nil }
        return AgentAttribution.parseTree(raw)
    }

    private static func route(ipv6: Bool) -> Result {
        guard case .success(let raw) = ProbeRunner.run("/sbin/route",
            ["-n", "get", ipv6 ? "-inet6" : "-inet", "default"], timeout: 2, maxBytes: 65536)
        else { return .unavailable }
        return DefaultRouteParser.interfaceName(raw) == nil ? .incompatible : .compatible
    }
}
