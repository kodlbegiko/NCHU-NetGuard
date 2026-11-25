#if SWIFT_PACKAGE
import NetGuardCore
#endif
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
        let result = DefaultRouteParser.inspect(raw)
        let family = ipv6 ? "ipv6" : "ipv4"
        print("\(family)_route_parse_status=\(result.status.rawValue)")
        return result.status == .parsed ? .compatible : .incompatible
    }

    struct FlowCheckReading: Sendable {
        let transport: FlowTransport
        let totals: [DestinationAddressKind: DestinationByteTotals]?
        let coverage: TCPFlowCoverage?
        let tunnelCandidate: Bool
        let diagnosticLines: [String]
    }

    /// One-shot, explicit observation. The result contains aggregates only.
    static func measureFlow(transport: FlowTransport) -> FlowCheckReading {
        var lines: [String] = []
        func snapshot(_ phase: String) -> ([TCPFlowCounter]?, TimeInterval) {
            let before = tree()
            let outcome = ProbeRunner.run("/usr/bin/nettop",
                ["-m", transport.rawValue, "-n", "-x", "-L", "1", "-J", "bytes_in,bytes_out,interface,state"], timeout: 5)
            let uptime = ProcessInfo.processInfo.systemUptime
            let after = tree()
            switch outcome {
            case .failed: lines.append("\(phase)_probe=failed"); return (nil, uptime)
            case .timedOut: lines.append("\(phase)_probe=timedOut"); return (nil, uptime)
            case .outputLimit: lines.append("\(phase)_probe=outputLimit"); return (nil, uptime)
            case .success(let raw):
                guard let before, let after else {
                    lines.append("\(phase)_probe=missingProcessEvidence")
                    return (nil, uptime)
                }
                var detail = FlowParseDiagnostics()
                let rows = TCPFlowParser.parse(raw, before: before.mapValues { $0.start },
                    after: after.mapValues { $0.start }, transport: transport, diagnostics: &detail)
                lines.append("\(phase)_parse=\(detail.status) candidate=\(detail.candidateRows) accepted=\(detail.acceptedRows) malformed=\(detail.malformedRows)")
                lines.append("\(phase)_rejected_owner=\(detail.ownerRejected) state=\(detail.stateRejected) counter=\(detail.counterRejected) interface=\(detail.interfaceRejected) endpoint=\(detail.endpointRejected) duplicate_identities=\(detail.duplicateIdentities)")
                return (rows, uptime)
            }
        }
        var accumulator = TCPFlowAccumulator()
        let first = snapshot("first")
        _ = accumulator.ingest(first.0, uptime: first.1)
        Thread.sleep(forTimeInterval: 1)
        let second = snapshot("second")
        let tunnelCandidate = ((first.0 ?? []) + (second.0 ?? [])).contains { TunnelEvidence.isTunnelCandidate($0.interface) }
        let totals = accumulator.ingest(second.0, uptime: second.1)
        return FlowCheckReading(transport: transport, totals: totals, coverage: accumulator.coverage,
            tunnelCandidate: tunnelCandidate, diagnosticLines: lines)
    }

    static func runFlowCheck(transport: FlowTransport = .tcp) -> Int32 {
        let marker = "NETGUARD_" + transport.rawValue.uppercased() + "_FLOW_CHECK"
        print(marker + "_V1")
        let reading = measureFlow(transport: transport)
        for line in reading.diagnosticLines { print(line) }
        print("tunnel_interface_candidate=" + (reading.tunnelCandidate ? "observed" : "not_observed"))
        print("overlap_exclusion=unverified")
        if let coverage = reading.coverage {
            print("prior_rows=\(coverage.priorRows) current_rows=\(coverage.currentRows) matched_rows=\(coverage.matchedRows)")
            print("new_rows=\(coverage.newRows) disappeared_rows=\(coverage.disappearedRows) reset_rows=\(coverage.resetRows)")
            print("matched_current_rows_fraction=\(coverage.matchedFraction) elapsed_seconds=\(coverage.elapsedSeconds)")
        }
        guard let totals = reading.totals else {
            print(marker + "_INCONCLUSIVE")
            return 2
        }
        for kind in totals.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let value = totals[kind] else { continue }
            print("\(kind.rawValue): received=\(value.received) sent=\(value.sent)")
        }
        print(marker + "_OK")
        return 0
    }
}
