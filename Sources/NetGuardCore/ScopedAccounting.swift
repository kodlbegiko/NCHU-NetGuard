import Foundation

public enum NetworkScope: String, Codable, CaseIterable, Sendable {
    case dorm, campusWifi, external, unknown
}

public struct ScopedInterfaceSample: Codable, Equatable, Sendable {
    public let counters: InterfaceCounters
    public let scope: NetworkScope
    /// Identity is local and ephemeral; changing it invalidates the attribution interval.
    public let identity: String
    public init(counters: InterfaceCounters, scope: NetworkScope, identity: String) {
        self.counters = counters
        self.scope = scope
        self.identity = identity
    }
}

public struct ScopedTrafficDelta: Equatable, Sendable {
    public let scope: NetworkScope
    public let delta: TrafficDelta
}

public struct ScopedCounterAccumulator: Sendable {
    private var accumulator = CounterAccumulator()
    private var previous: [String: ScopedInterfaceSample] = [:]
    private var previousDay: String?
    private var previousUptime: TimeInterval?
    public init() {}

    public mutating func reset() { self = Self() }

    /// A boundary/gap invalidates interval attribution; never invent bytes across it.
    public mutating func ingest(_ samples: [ScopedInterfaceSample], day: String,
                                uptime: TimeInterval, maxGap: TimeInterval = 5)
        -> [String: ScopedTrafficDelta] {
        let ids = Set(samples.map { $0.counters.interfaceID })
        let missing = Set(previous.keys).subtracting(ids)
        let invalid = ScopedTrafficDelta(scope: .unknown,
            delta: TrafficDelta(received: 0, sent: 0, quality: .unknown))
        guard uptime.isFinite, uptime >= 0, maxGap.isFinite, maxGap > 0 else {
            let affected = ids.union(previous.keys)
            reset()
            return Dictionary(uniqueKeysWithValues: affected.map { ($0, invalid) })
        }
        if previousDay != day ||
            previousUptime.map({ uptime <= $0 || uptime - $0 > maxGap }) == true {
            reset()
        }
        previousDay = day
        previousUptime = uptime
        let counts = Dictionary(grouping: samples, by: { $0.counters.interfaceID })
        let deltas = accumulator.ingest(samples.map(\.counters))
        var next: [String: ScopedInterfaceSample] = [:]
        var result = Dictionary(uniqueKeysWithValues: missing.map { ($0, invalid) })
        for (id, group) in counts {
            guard group.count == 1, let sample = group.first, let delta = deltas[id] else {
                result[id] = ScopedTrafficDelta(scope: .unknown,
                    delta: TrafficDelta(received: 0, sent: 0, quality: .unknown))
                continue
            }
            next[id] = sample
            let stable = previous[id]?.scope == sample.scope &&
                         previous[id]?.identity == sample.identity
            result[id] = ScopedTrafficDelta(scope: stable ? sample.scope : .unknown,
                                            delta: delta)
        }
        previous = next
        return result
    }
}

/// Duplicate interface identities are ambiguous, not a reason to trap.
public enum InterfaceScopeProjection {
    public static func scopes(_ samples: [ScopedInterfaceSample]) -> [String: NetworkScope] {
        Dictionary(grouping: samples, by: { $0.counters.interfaceID }).mapValues { group in
            group.count == 1 ? (group.first?.scope ?? .unknown) : .unknown
        }
    }
}
