import Foundation

/// Experimental TCP-only, hierarchical nettop CSV adapter. The tuple is
/// heuristic socket identity, not an OS-issued socket generation identifier.
public struct TCPFlowCounter: Equatable, Sendable {
    public let identity: String
    public let remote: String
    public let received: UInt64
    public let sent: UInt64
}

public enum TCPFlowParser {
    /// Initial supported layout: numeric IPv4 TCP endpoints and Established
    /// state only. Process summary rows never contribute bytes.
    public static func parse(_ output: String, before: [Int: String], after: [Int: String]) -> [TCPFlowCounter]? {
        guard output.utf8.count <= 1_048_576, !before.isEmpty, !after.isEmpty else { return nil }
        var columns: [String: Int]?
        var owner: (Int, String, String)?
        var rows: [String: TCPFlowCounter] = [:]
        var ambiguous = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.last == "" { fields.removeLast() }
            guard fields.count == 5 else { owner = nil; continue }
            if Set(fields.dropFirst()) == Set(["bytes_in", "bytes_out", "interface", "state"]) {
                // A second header would represent a different observation.
                guard columns == nil else { return nil }
                columns = Dictionary(uniqueKeysWithValues: fields.dropFirst().enumerated().map { ($0.element, $0.offset + 1) })
                owner = nil
                continue
            }
            guard let columns else { continue }
            let label = fields[0]
            if !label.hasPrefix("tcp4 ") && !label.hasPrefix("tcp6 ") {
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
            guard label.hasPrefix("tcp4 "), let owner,
                  fields[columns["state"]!] == "Established",
                  let rx = UInt64(fields[columns["bytes_in"]!]),
                  let tx = UInt64(fields[columns["bytes_out"]!]) else { continue }
            let iface = fields[columns["interface"]!]
            guard (1...32).contains(iface.utf8.count), iface.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }) else { continue }
            let ends = String(label.dropFirst(5)).components(separatedBy: "<->")
            guard ends.count == 2, let local = endpoint(ends[0]), let remote = endpoint(ends[1]) else { continue }
            let identity = "\(owner.0)|\(owner.1.utf8.count):\(owner.1)|\(owner.2.utf8.count):\(owner.2)|\(iface)|\(local.0):\(local.1)|\(remote.0):\(remote.1)"
            let row = TCPFlowCounter(identity: identity, remote: remote.0, received: rx, sent: tx)
            if rows.updateValue(row, forKey: identity) != nil { ambiguous.insert(identity) }
            guard rows.count <= 4096 else { return nil }
        }
        guard columns != nil else { return nil }
        for id in ambiguous { rows.removeValue(forKey: id) }
        return rows.values.sorted { $0.identity < $1.identity }
    }

    private static func endpoint(_ input: String) -> (String, UInt16)? {
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
public struct TCPFlowAccumulator: Sendable {
    private var previous: [String: TCPFlowCounter] = [:]
    private var last: TimeInterval?
    public init() {}
    public mutating func reset() { previous = [:]; last = nil }
    public mutating func ingest(_ rows: [TCPFlowCounter]?, uptime: TimeInterval) -> [DestinationAddressKind: DestinationByteTotals]? {
        guard let rows, !rows.isEmpty, rows.count <= 4096, uptime.isFinite, uptime >= 0,
              Set(rows.map(\.identity)).count == rows.count else { reset(); return nil }
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.identity, $0) })
        defer { previous = current; last = uptime }
        guard let last, uptime > last, uptime - last <= 15 else { return nil }
        let deltas: [DestinationFlowDelta] = rows.enumerated().compactMap { index, row in
            guard let old = previous[row.identity], old.remote == row.remote,
                  row.received >= old.received, row.sent >= old.sent else { return nil }
            return .init(flowID: String(index), remoteAddress: row.remote,
                         received: row.received - old.received, sent: row.sent - old.sent)
        }
        return DestinationFlowProjection.summarize(deltas)
    }
}
