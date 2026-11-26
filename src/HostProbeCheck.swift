#if SWIFT_PACKAGE
import NetGuardCore
#endif
import Foundation
import Darwin

/// Read a single interface through the documented IFMIB general-data MIB.
/// No 32-bit AF_LINK fallback, shell, private framework or counter guessing.
enum InterfaceMIBReader {
    struct Reading {
        let counters: InterfaceCounters
        let index: UInt32
    }
    static func read(_ name: String) -> Reading? {
        guard !name.isEmpty, name.utf8.count < Int(IFNAMSIZ),
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { return nil }
        let index = if_nametoindex(name)
        guard index > 0, let signedIndex = Int32(exactly: index) else { return nil }
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, signedIndex, IFDATA_GENERAL]
        var record = ifmibdata()
        var length = MemoryLayout<ifmibdata>.size
        let rc = mib.withUnsafeMutableBufferPointer { path in
            sysctl(path.baseAddress, u_int(path.count), &record, &length, nil, 0)
        }
        guard rc == 0, length == MemoryLayout<ifmibdata>.size,
              MemoryLayout.size(ofValue: record.ifmd_data.ifi_ibytes) == 8,
              MemoryLayout.size(ofValue: record.ifmd_data.ifi_obytes) == 8,
              if_nametoindex(name) == index else { return nil }
        let returnedName = withUnsafeBytes(of: record.ifmd_name) { bytes -> String? in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
        guard returnedName == name else { return nil }
        return Reading(counters: .init(interfaceID: name,
            received: UInt64(record.ifmd_data.ifi_ibytes), sent: UInt64(record.ifmd_data.ifi_obytes)), index: index)
    }

    static func compatibility() -> Bool {
        // Only a read of the local loopback; no packets sent, no names or
        // raw counters printed. This is API compatibility, not accuracy.
        guard let first = read("lo0"), let second = read("lo0") else { return false }
        return first.index == second.index && second.counters.received >= first.counters.received &&
            second.counters.sent >= first.counters.sent
    }
}

/// The local compatibility check emits only coarse outcome categories.
/// No network requests, raw command output, PIDs, paths, addresses or names.
enum HostProbeCheck {
    enum Result: String {
        case compatible, unavailable, incompatible, insufficient
    }

    static func run() -> Int32 {
        let before = tree()
        let nettop = ProbeRunner.runApproved("/usr/bin/nettop", ["-P", "-L", "1", "-J", "bytes_in,bytes_out"], timeout: 5)
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
        let interfaceCounters = InterfaceMIBReader.compatibility()
        print("NETGUARD_HOST_CHECK_V1")
        print("ifmib_64bit=\(interfaceCounters ? "compatible" : "inconclusive")")
        print("ps=\(ps.rawValue)")
        print("nettop=\(counters.rawValue)")
        print("ipv4_default_route=\(v4.rawValue)")
        print("ipv6_default_route=\(v6.rawValue)")
        // A missing route is not a parser failure, and a zero-row snapshot
        // is not affirmative process-counter compatibility.
        guard interfaceCounters, ps == .compatible, counters == .compatible,
              v4 != .incompatible, v6 != .incompatible,
              v4 == .compatible || v6 == .compatible else {
            print("NETGUARD_HOST_CHECK_INCONCLUSIVE")
            return 2
        }
        print("NETGUARD_HOST_CHECK_OK")
        return 0
    }

    private static func tree() -> [Int: ProcessTreeNode]? {
        guard case .success(let raw) = ProbeRunner.runApproved("/bin/ps",
            ["-ax", "-o", "pid=,ppid=,lstart=,comm="], timeout: 2) else { return nil }
        return AgentAttribution.parseTree(raw)
    }

    private static func route(ipv6: Bool) -> Result {
        guard case .success(let raw) = ProbeRunner.runApproved("/sbin/route",
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
        let routeCandidates: [ObservedRouteKind: DailyScopeTotals]?
        let tunnelCandidate: Bool
        let diagnosticLines: [String]
    }

    /// One-shot, explicit observation. The result contains aggregates only.
    static func measureFlow(transport: FlowTransport) -> FlowCheckReading {
        var lines: [String] = []
        func snapshot(_ phase: String) -> ([TCPFlowCounter]?, TimeInterval) {
            let before = tree()
            let outcome = ProbeRunner.runApproved("/usr/bin/nettop",
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
        // At most three distinct numeric peers; local routing-table queries
        // only, no DNS or packets. Never retain peer identities in the result.
        let peers = Array(Set((first.0 ?? []).map(\.remote)).sorted().prefix(3))
        func routes() -> [String: RoutePathEvidence] {
            var result: [String: RoutePathEvidence] = [:]
            for peer in peers {
                guard !peer.isEmpty, peer.utf8.count <= 64,
                      peer.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) ||
                          (65...70).contains($0) || $0 == 46 || $0 == 58 }) else { continue }
                if case .success(let raw) = ProbeRunner.runApproved("/sbin/route",
                    ["-n", "get", peer.contains(":") ? "-inet6" : "-inet", peer],
                    timeout: 0.75, maxBytes: 16_384), let evidence = RoutePathParser.inspect(raw) {
                    result[peer] = evidence
                }
            }
            return result
        }
        let beforeRoutes = routes()
        Thread.sleep(forTimeInterval: 1)
        let second = snapshot("second")
        let tunnelCandidate = ((first.0 ?? []) + (second.0 ?? [])).contains { TunnelEvidence.isTunnelCandidate($0.interface) }
        let totals = accumulator.ingest(second.0, uptime: second.1)
        let afterRoutes = routes()
        var buckets: [ObservedRouteKind: DailyScopeTotals] = [:]
        var valid = totals != nil
        for row in accumulator.matchedDeltas {
            let kind = RoutePathParser.classify(before: beforeRoutes[row.remote], after: afterRoutes[row.remote],
                flowInterface: row.interface, tunnelOverlap: tunnelCandidate)
            let old = buckets[kind] ?? DailyScopeTotals()
            let (rx, a) = old.received.addingReportingOverflow(row.received)
            let (tx, b) = old.sent.addingReportingOverflow(row.sent)
            if a || b || rx.addingReportingOverflow(tx).overflow { valid = false; break }
            buckets[kind] = .init(received: rx, sent: tx)
        }
        return FlowCheckReading(transport: transport, totals: totals, coverage: accumulator.coverage,
            routeCandidates: valid ? buckets : nil, tunnelCandidate: tunnelCandidate, diagnosticLines: lines)
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
        if let candidates = reading.routeCandidates {
            for kind in candidates.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let value = candidates[kind] else { continue }
                print("route_candidate_\(kind.rawValue): received=\(value.received) sent=\(value.sent)")
            }
        }
        print(marker + "_OK")
        return 0
    }
}
