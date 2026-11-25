import Foundation

/// A completed ICMP echo probe, not an estimate of all network packet loss.
public struct EchoProbeReading: Equatable, Sendable {
    public let sent: Int
    public let received: Int
    public let averageMilliseconds: Double?
    public var lossFraction: Double { Double(sent - received) / Double(sent) }
}

public enum EchoProbeParser {
    public static func parse(_ output: String, expectedCount: Int) -> EchoProbeReading? {
        guard (1...10).contains(expectedCount), output.utf8.count <= 65_536 else { return nil }
        let pattern = #"(?m)^(\d+) packets transmitted, (\d+) packets received, [0-9.]+% packet loss[^\r\n]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
        guard matches.count == 1, let match = matches.first,
              let sent = Int(ns.substring(with: match.range(at: 1))),
              let received = Int(ns.substring(with: match.range(at: 2))),
              sent == expectedCount, (0...sent).contains(received) else { return nil }
        if received == 0 { return .init(sent: sent, received: received, averageMilliseconds: nil) }
        let timing = #"(?m)^(?:round-trip|rtt) min/avg/max/(?:stddev|mdev) = ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+) ms\s*$"#
        guard let expression = try? NSRegularExpression(pattern: timing) else { return nil }
        let times = expression.matches(in: output, range: NSRange(location: 0, length: ns.length))
        guard times.count == 1, let t = times.first,
              let minimum = Double(ns.substring(with: t.range(at: 1))),
              let average = Double(ns.substring(with: t.range(at: 2))),
              let maximum = Double(ns.substring(with: t.range(at: 3))),
              minimum.isFinite, average.isFinite, maximum.isFinite,
              minimum >= 0, minimum <= average, average <= maximum else { return nil }
        return .init(sent: sent, received: received, averageMilliseconds: average)
    }
}

public struct EchoProbeWindow: Sendable {
    private var observations: [(TimeInterval, EchoProbeReading)] = []
    public init() {}
    public mutating func reset() { observations.removeAll() }
    public mutating func ingest(_ reading: EchoProbeReading?, at uptime: TimeInterval) {
        guard let reading, uptime.isFinite, uptime >= 0,
              observations.last.map({ uptime > $0.0 }) ?? true else { reset(); return }
        observations.append((uptime, reading))
        observations.removeAll { uptime - $0.0 > 180 }
        if observations.count > 10 { observations.removeFirst(observations.count - 10) }
    }
    public func summary(at uptime: TimeInterval) -> EchoProbeReading? {
        guard uptime.isFinite, let last = observations.last,
              uptime >= last.0, uptime - last.0 <= 120 else { return nil }
        let fresh = observations.filter { uptime - $0.0 <= 180 }.map(\.1)
        let sent = fresh.reduce(0) { $0 + $1.sent }
        let received = fresh.reduce(0) { $0 + $1.received }
        guard sent > 0 else { return nil }
        let weighted = fresh.reduce(0.0) { $0 + ($1.averageMilliseconds ?? 0) * Double($1.received) }
        return .init(sent: sent, received: received, averageMilliseconds: received > 0 ? weighted / Double(received) : nil)
    }
}

/// Timing from a DNS response as reported by dig, not system resolver latency.
public struct DNSProbeReading: Equatable, Sendable {
    public let status: String
    public let milliseconds: Int
}

public enum DNSProbeParser {
    public static func parse(_ output: String) -> DNSProbeReading? {
        guard output.utf8.count <= 65_536 else { return nil }
        let ns = output as NSString
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let matches = regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
            guard matches.count == 1, let match = matches.first else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
        guard let status = capture(#"(?m)^;; ->>HEADER<<- opcode: QUERY, status: ([A-Z0-9]+),"#),
              let raw = capture(#"(?m)^;; Query time: (\d+) msec\s*$"#),
              let ms = Int(raw), (0...60_000).contains(ms) else { return nil }
        return .init(status: status, milliseconds: ms)
    }
}
