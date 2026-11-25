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

/// ps lstart is a local wall-clock string, not authenticated process identity.
enum ProcessStartEvidence {
    static func validate(_ fields: [Substring]) -> String? {
        guard fields.count == 5, ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"].contains(String(fields[0])),
              let month = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"].firstIndex(of: String(fields[1])),
              let day = Int(fields[2]), let year = Int(fields[4]), (1970...9999).contains(year),
              fields[3].utf8.count == 8 else { return nil }
        let time = fields[3].split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 3, time.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let hour = Int(time[0]), let minute = Int(time[1]), let second = Int(time[2]),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: parts),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month + 1,
              calendar.component(.day, from: date) == day,
              ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][calendar.component(.weekday, from: date) - 1] == String(fields[0])
        else { return nil }
        return fields.joined(separator: " ")
    }
}

public enum ProcessCounterParser {
    public static func starts(_ output: String) -> [Int: String] {
        guard output.utf8.count <= 1_048_576 else { return [:] }
        var result: [Int: String] = [:]
        var seen = Set<Int>()
        var ambiguous = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, let pid = Int(first), pid > 0 else { continue }
            if !seen.insert(pid).inserted { ambiguous.insert(pid) }
            guard seen.count <= 8192 else { return [:] }
            guard fields.count == 6, let start = ProcessStartEvidence.validate(Array(fields.dropFirst())) else { continue }
            result[pid] = start
        }
        for pid in ambiguous { result.removeValue(forKey: pid) }
        return result
    }

    /// Strict labeled columns. Unsupported layouts are unavailable, never zero.
    /// Names with CSV delimiters or missing PID are excluded.
    public static func parse(_ output: String, before: [Int: String], after: [Int: String]) -> [ProcessCounter]? {
        guard output.utf8.count <= 1_048_576, before.count <= 8192, after.count <= 8192 else { return nil }
        var header = false
        var seen = Set<Int>()
        var rows: [Int: ProcessCounter] = [:]
        var ambiguous = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.last == "" { fields.removeLast() }
            guard fields.count == 3 else { continue }
            if fields[1] == "bytes_in", fields[2] == "bytes_out" {
                guard !header else { return nil }
                header = true; continue
            }
            guard header, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int(fields[0][fields[0].index(after: dot)...]), pid > 0 else { continue }
            if !seen.insert(pid).inserted { ambiguous.insert(pid) }
            guard seen.count <= 4096 else { return nil }
            guard let start = before[pid], after[pid] == start,
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
