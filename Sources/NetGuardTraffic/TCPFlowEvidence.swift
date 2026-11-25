import Foundation
import Darwin

/// Experimental hierarchical nettop CSV adapter (TCP or UDP, separately). The tuple is
/// heuristic socket identity, not an OS-issued socket generation identifier.
public enum FlowTransport: String, Sendable {
    case tcp, udp
}

public struct TCPFlowCounter: Equatable, Sendable {
    public let identity: String
    public let remote: String
    public let transport: FlowTransport
    public let interface: String
    public let received: UInt64
    public let sent: UInt64
}

public struct FlowParseDiagnostics: Equatable, Sendable {
    public var status = "notParsed"
    public var candidateRows = 0
    public var malformedRows = 0
    public var ownerRejected = 0
    public var stateRejected = 0
    public var counterRejected = 0
    public var interfaceRejected = 0
    public var endpointRejected = 0
    public var duplicateIdentities = 0
    public var acceptedRows = 0
    public init() {}
}

public enum TCPFlowParser {
    /// Numeric IPv4 / bracketed IPv6 endpoints. TCP Established only;
    /// UDP explicit peer endpoints and recognized state fields only.
    /// Process summary rows never contribute bytes; UDP is not proof of QUIC.
    public static func parse(_ output: String, before: [Int: String], after: [Int: String], transport: FlowTransport = .tcp) -> [TCPFlowCounter]? {
        var diagnostics = FlowParseDiagnostics()
        return parse(output, before: before, after: after, transport: transport, diagnostics: &diagnostics)
    }

    public static func parse(_ output: String, before: [Int: String], after: [Int: String],
                             transport: FlowTransport, diagnostics: inout FlowParseDiagnostics) -> [TCPFlowCounter]? {
        diagnostics = FlowParseDiagnostics()
        guard output.utf8.count <= 1_048_576 else { diagnostics.status = "outputLimit"; return nil }
        guard !before.isEmpty, !after.isEmpty else { diagnostics.status = "missingProcessEvidence"; return nil }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { diagnostics.status = "emptyOutput"; return nil }
        var columns: [String: Int]?
        var owner: (Int, String, String)?
        var rows: [String: TCPFlowCounter] = [:]
        var ambiguous = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.last == "" { fields.removeLast() }
            guard fields.count == 5 else { diagnostics.malformedRows += 1; owner = nil; continue }
            if Set(fields.dropFirst()) == Set(["bytes_in", "bytes_out", "interface", "state"]) {
                // A second header would represent a different observation.
                guard columns == nil else { diagnostics.status = "repeatedHeader"; return nil }
                columns = Dictionary(uniqueKeysWithValues: fields.dropFirst().enumerated().map { ($0.element, $0.offset + 1) })
                owner = nil
                continue
            }
            guard let columns else { continue }
            let label = fields[0]
            let v4Prefix = transport.rawValue + "4 "
            let v6Prefix = transport.rawValue + "6 "
            if !label.hasPrefix(v4Prefix) && !label.hasPrefix(v6Prefix) {
                owner = nil
                guard !label.contains("<->"), let dot = label.lastIndex(of: "."),
                      let pid = Int(label[label.index(after: dot)...]), pid > 0,
                      let start = before[pid], start == after[pid] else { continue }
                let name = String(label[..<dot])
                guard !name.isEmpty, name.utf8.count <= 128, !name.contains("\""),
                      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
                owner = (pid, start, name)
                continue
            }
            diagnostics.candidateRows += 1
            let state = fields[columns["state"]!]
            // UDP has no TCP-style handshake. Require explicit endpoints;
            // only initial known fixture states are accepted.
            let acceptedState = transport == .tcp ? state == "Established" : (state.isEmpty || state == "Connected")
            guard let owner else { diagnostics.ownerRejected += 1; continue }
            guard acceptedState else { diagnostics.stateRejected += 1; continue }
            guard let rx = UInt64(fields[columns["bytes_in"]!]),
                  let tx = UInt64(fields[columns["bytes_out"]!]) else { diagnostics.counterRejected += 1; continue }
            let iface = fields[columns["interface"]!]
            guard (1...32).contains(iface.utf8.count), iface.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }) else { diagnostics.interfaceRejected += 1; continue }
            let ends = String(label.dropFirst(5)).components(separatedBy: "<->")
            guard ends.count == 2, let local = endpoint(ends[0], ipv6: label.hasPrefix(v6Prefix)), let remote = endpoint(ends[1], ipv6: label.hasPrefix(v6Prefix)) else { diagnostics.endpointRejected += 1; continue }
            let identity = "\(owner.0)|\(owner.1.utf8.count):\(owner.1)|\(owner.2.utf8.count):\(owner.2)|\(iface)|\(label.prefix(4))|[\(local.0)]:\(local.1)|[\(remote.0)]:\(remote.1)"
            let row = TCPFlowCounter(identity: identity, remote: remote.0, transport: transport, interface: iface, received: rx, sent: tx)
            if rows.updateValue(row, forKey: identity) != nil { ambiguous.insert(identity) }
            guard rows.count <= 4096 else { diagnostics.status = "rowLimit"; return nil }
        }
        guard columns != nil else { diagnostics.status = "missingHeader"; return nil }
        for id in ambiguous { rows.removeValue(forKey: id) }
        diagnostics.duplicateIdentities = ambiguous.count
        diagnostics.acceptedRows = rows.count
        diagnostics.status = rows.isEmpty ? "noAcceptedRows" : "parsed"
        return rows.values.sorted { $0.identity < $1.identity }
    }

    private static func endpoint(_ input: String, ipv6: Bool) -> (String, UInt16)? {
        if ipv6 {
            // Only bracketed numeric IPv6 with explicit port; reject scoped
            // literals until interface-zone attribution is independently verified.
            guard input.hasPrefix("["), let closing = input.firstIndex(of: "]"),
                  input.index(after: closing) < input.endIndex,
                  input[input.index(after: closing)] == ":" else { return nil }
            let address = String(input[input.index(after: input.startIndex)..<closing])
            let portStart = input.index(closing, offsetBy: 2)
            guard !address.contains("%"), !address.utf8.contains(0), address.utf8.count <= 64,
                  let port = UInt16(input[portStart...]), port > 0 else { return nil }
            var raw = in6_addr()
            guard inet_pton(AF_INET6, address, &raw) == 1,
                  !withUnsafeBytes(of: &raw, { $0.allSatisfy { $0 == 0 } }) else { return nil }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &output, socklen_t(output.count)) != nil else { return nil }
            return (String(cString: output), port)
        }
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0 else { return nil }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        let bytes = octets.compactMap { UInt8($0) }
        guard bytes.count == 4, zip(octets, bytes).allSatisfy({ String($0.0) == String($0.1) }) else { return nil }
        let ip = bytes.map(String.init).joined(separator: ".")
        guard ip != "0.0.0.0", ip != "255.255.255.255" else { return nil }
        return (ip, port)
    }
}

/// Two adjacent snapshots only. Missing/reopened/reset sockets are omitted;
/// identical tuples can still be reused between samples. No full coverage.
public struct TCPFlowCoverage: Equatable, Sendable {
    public let priorRows: Int
    public let currentRows: Int
    public let matchedRows: Int
    public let newRows: Int
    public let disappearedRows: Int
    public let resetRows: Int
    public let elapsedSeconds: TimeInterval
    // Snapshot row coverage, not coverage of bytes, packets or all sockets.
    public var matchedFraction: Double { Double(matchedRows) / Double(max(1, currentRows)) }
}

public struct TCPFlowAccumulator: Sendable {
    private var previous: [String: TCPFlowCounter] = [:]
    private var last: TimeInterval?
    public init() {}
    public private(set) var coverage: TCPFlowCoverage?
    public mutating func reset() { previous = [:]; last = nil; coverage = nil }
    public mutating func ingest(_ rows: [TCPFlowCounter]?, uptime: TimeInterval) -> [DestinationAddressKind: DestinationByteTotals]? {
        guard let rows, !rows.isEmpty, rows.count <= 4096, uptime.isFinite, uptime >= 0,
              let transport = rows.first?.transport, rows.allSatisfy({ $0.transport == transport }),
              Set(rows.map(\.identity)).count == rows.count else { reset(); return nil }
        coverage = nil
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.identity, $0) })
        defer { previous = current; last = uptime }
        guard let last, uptime > last, uptime - last <= 15,
              previous.values.allSatisfy({ $0.transport == transport }) else { return nil }
        let deltas: [DestinationFlowDelta] = rows.enumerated().compactMap { index, row in
            guard let old = previous[row.identity], old.remote == row.remote, old.interface == row.interface,
                  row.received >= old.received, row.sent >= old.sent else { return nil }
            return .init(flowID: String(index), remoteAddress: row.remote,
                         received: row.received - old.received, sent: row.sent - old.sent)
        }
        let new = current.keys.filter { previous[$0] == nil }.count
        let disappeared = previous.keys.filter { current[$0] == nil }.count
        coverage = TCPFlowCoverage(priorRows: previous.count, currentRows: current.count,
            matchedRows: deltas.count, newRows: new, disappearedRows: disappeared,
            resetRows: current.count - new - deltas.count, elapsedSeconds: uptime - last)
        return DestinationFlowProjection.summarize(deltas)
    }
}
