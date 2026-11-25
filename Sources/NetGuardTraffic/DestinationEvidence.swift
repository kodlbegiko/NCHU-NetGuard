import Foundation
import Darwin

/// Address semantics, not a determination of the path, ownership or billing
/// treatment of a packet. Private space can be reached through a VPN; public
/// space can be directly connected. Keep those cases distinct.
public enum DestinationAddressKind: String, Codable, Sendable {
    case loopback, linkLocal, privateSpace, sharedSpace, multicast
    case specialUse, publicCandidate, unknown

    public static func classify(_ literal: String) -> Self {
        guard !literal.isEmpty, literal.utf8.count <= 64,
              !literal.utf8.contains(0), !literal.contains("%") else { return .unknown }
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { classifyV4(Array($0)) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, literal, &v6) == 1 else { return .unknown }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        guard b.count == 16 else { return .unknown }
        if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 255, b[11] == 255 {
            return classifyV4(Array(b.suffix(4)))
        }
        if b.dropLast().allSatisfy({ $0 == 0 }) {
            return b.last == 1 ? .loopback : .specialUse
        }
        if b[0] == 0xff { return .multicast }
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return .linkLocal }
        if b[0] & 0xfe == 0xfc { return .privateSpace }
        // Only currently allocated global-unicast space is a public candidate.
        // Exclude documentation and transition/protocol-assignment prefixes.
        guard b[0] & 0xe0 == 0x20 else { return .specialUse }
        if b[0] == 0x20 && b[1] == 0x01 &&
            ((b[2] & 0xfe == 0) || (b[2] == 0x0d && b[3] == 0xb8)) { return .specialUse }
        if b[0] == 0x20 && b[1] == 0x02 { return .specialUse }
        if b[0] == 0x3f && b[1] == 0xff && b[2] & 0xf0 == 0 { return .specialUse }
        return .publicCandidate
    }

    private static func classifyV4(_ b: [UInt8]) -> Self {
        guard b.count == 4 else { return .unknown }
        let a = b[0], c = b[1], d = b[2]
        if a == 127 { return .loopback }
        if a == 169 && c == 254 { return .linkLocal }
        if a == 10 || (a == 172 && (16...31).contains(c)) || (a == 192 && c == 168) { return .privateSpace }
        if a == 100 && (64...127).contains(c) { return .sharedSpace }
        if (224...239).contains(a) { return .multicast }
        if a == 0 || a >= 240 ||
            (a == 192 && c == 0 && (d == 0 || d == 2)) ||
            (a == 192 && c == 88 && d == 99) ||
            (a == 198 && (c == 18 || c == 19)) ||
            (a == 198 && c == 51 && d == 100) ||
            (a == 203 && c == 0 && d == 113) { return .specialUse }
        return .publicCandidate
    }
}

/// Only independent, non-overlapping, measured flow deltas from an adapter
/// may be aggregated here. A network-interface total is NOT a flow delta.
/// The evidence identity is ephemeral and is never returned or persisted.
public struct DestinationFlowDelta: Sendable {
    public let flowID: String
    public let remoteAddress: String
    public let received: UInt64
    public let sent: UInt64
    public init(flowID: String, remoteAddress: String, received: UInt64, sent: UInt64) {
        self.flowID = flowID; self.remoteAddress = remoteAddress
        self.received = received; self.sent = sent
    }
}

public struct DestinationByteTotals: Equatable, Sendable {
    public let received: UInt64
    public let sent: UInt64
    public var total: UInt64 { received + sent }
}

public enum DestinationFlowProjection {
    /// Nil means no usable observation or ambiguous evidence, never zero.
    /// Unrecognized addresses stay in unknown; no LAN/Internet inference.
    public static func summarize(_ rows: [DestinationFlowDelta]) -> [DestinationAddressKind: DestinationByteTotals]? {
        guard !rows.isEmpty, rows.count <= 4096 else { return nil }
        var seen = Set<String>()
        var aggregate: UInt64 = 0
        var totals: [DestinationAddressKind: DestinationByteTotals] = [:]
        for row in rows {
            guard !row.flowID.isEmpty, row.flowID.utf8.count <= 256,
                  seen.insert(row.flowID).inserted else { return nil }
            let (rowTotal, rowOverflow) = row.received.addingReportingOverflow(row.sent)
            let (combined, aggregateOverflow) = aggregate.addingReportingOverflow(rowTotal)
            guard !rowOverflow, !aggregateOverflow else { return nil }
            aggregate = combined
            let kind = DestinationAddressKind.classify(row.remoteAddress)
            let (rx, a) = (totals[kind]?.received ?? 0).addingReportingOverflow(row.received)
            let (tx, b) = (totals[kind]?.sent ?? 0).addingReportingOverflow(row.sent)
            let (_, c) = rx.addingReportingOverflow(tx)
            guard !a, !b, !c else { return nil }
            totals[kind] = .init(received: rx, sent: tx)
        }
        return totals
    }
}
