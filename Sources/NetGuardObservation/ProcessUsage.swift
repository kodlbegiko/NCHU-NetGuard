import Foundation

/// Identity is observed before and after nettop, not inferred from display name.
/// ps lstart has second-level resolution: this is not cryptographic identity.
public struct ProcessCounter: Equatable, Sendable {
    public let pid: Int
    public let name: String
    public let start: String
    public let received: UInt64
    public let sent: UInt64
    public init(pid: Int, name: String, start: String, received: UInt64, sent: UInt64) {
        self.pid = pid; self.name = name; self.start = start; self.received = received; self.sent = sent
    }
}

public enum ProcessCounterParser {
    public static func starts(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var ambiguous = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 6, let pid = Int(fields[0]), pid > 0,
                  fields[4].range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil,
                  Int(fields[5]) != nil else { continue }
            if result.updateValue(fields.dropFirst().joined(separator: " "), forKey: pid) != nil {
                ambiguous.insert(pid)
            }
        }
        for pid in ambiguous { result.removeValue(forKey: pid) }
        return result
    }

    /// Strict labeled columns. Unsupported layouts are unavailable, never zero.
    /// Names with CSV delimiters or missing PID are excluded.
    public static func parse(_ output: String, before: [Int: String], after: [Int: String]) -> [ProcessCounter]? {
        var header = false
        var rows: [Int: ProcessCounter] = [:]
        var ambiguous = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.last == "" { fields.removeLast() }
            guard fields.count == 3 else { continue }
            if fields[1] == "bytes_in", fields[2] == "bytes_out" {
                header = true; continue
            }
            guard header, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int(fields[0][fields[0].index(after: dot)...]), pid > 0,
                  let start = before[pid], after[pid] == start,
                  let received = UInt64(fields[1]), let sent = UInt64(fields[2]) else { continue }
            let name = String(fields[0][..<dot])
            guard !name.isEmpty, name.utf8.count <= 128,
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !name.contains("\"") else { continue }
            if rows.updateValue(.init(pid: pid, name: name, start: start, received: received, sent: sent),
                                forKey: pid) != nil { ambiguous.insert(pid) }
        }
        guard header else { return nil }
        for pid in ambiguous { rows.removeValue(forKey: pid) }
        return rows.values.sorted { $0.pid < $1.pid }
    }
}

public struct ProcessUsageRow: Equatable, Sendable, Identifiable {
    public let name: String
    public let received: UInt64
    public let sent: UInt64
    public var id: String { name }
    public var total: UInt64 { received + sent }
}

public struct ProcessUsageReport: Equatable, Sendable {
    public let rows: [ProcessUsageRow]
    public let measuredIntervals: Int
    public let matchedIntervalSeconds: TimeInterval
    public let lastObservedUptime: TimeInterval?
    public let capacityReached: Bool
}

/// Session-only lower-bound observations, never an authoritative quota ledger.
/// Only matching PID/start/name pairs with monotonic counters yield deltas.
/// Disappearing processes, resets and unsampled intervals cannot be recovered.
public struct ProcessUsageAccumulator: Sendable {
    private var previous: [Int: ProcessCounter] = [:]
    private var last: TimeInterval?
    private var totals: [String: ProcessUsageRow] = [:]
    private var intervals = 0
    private var matchedSeconds: TimeInterval = 0
    private var observed: TimeInterval?
    private var capacityReached = false
    public init() {}
    public mutating func breakContinuity() {
        previous = [:]; last = nil
    }
    public mutating func ingest(_ counters: [ProcessCounter]?, uptime: TimeInterval) {
        guard let counters, uptime.isFinite, uptime >= 0, counters.count <= 4096 else {
            breakContinuity(); return
        }
        var current: [Int: ProcessCounter] = [:]
        var ambiguous = Set<Int>()
        for counter in counters {
            guard counter.pid > 0, !counter.start.isEmpty, !counter.name.isEmpty,
                  counter.name.utf8.count <= 128 else { continue }
            if current.updateValue(counter, forKey: counter.pid) != nil { ambiguous.insert(counter.pid) }
        }
        for pid in ambiguous { current.removeValue(forKey: pid) }
        defer { previous = current; last = uptime }
        guard let last, uptime > last, uptime - last <= 45 else { return }
        var matched = false
        for row in current.values {
            guard let old = previous[row.pid], old.start == row.start, old.name == row.name,
                  row.received >= old.received, row.sent >= old.sent else { continue }
            matched = true
            let rx = row.received - old.received, tx = row.sent - old.sent
            guard rx > 0 || tx > 0 else { continue }
            if totals[row.name] == nil && totals.count >= 1024 { capacityReached = true; continue }
            let existing = totals[row.name]
            let (received, a) = (existing?.received ?? 0).addingReportingOverflow(rx)
            let (sent, b) = (existing?.sent ?? 0).addingReportingOverflow(tx)
            let (_, c) = received.addingReportingOverflow(sent)
            guard !a, !b, !c else { capacityReached = true; continue }
            totals[row.name] = .init(name: row.name, received: received, sent: sent)
        }
        if matched {
            intervals = min(intervals + 1, Int.max - 1)
            matchedSeconds += uptime - last
            observed = uptime
        }
    }
    public func report() -> ProcessUsageReport {
        .init(rows: totals.values.sorted { $0.total == $1.total ? $0.name < $1.name : $0.total > $1.total },
              measuredIntervals: intervals, matchedIntervalSeconds: matchedSeconds, lastObservedUptime: observed, capacityReached: capacityReached)
    }
}
