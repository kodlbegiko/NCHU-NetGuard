import Foundation

public enum NetworkScope: String, Codable, CaseIterable, Sendable {
    case dorm, campusWifi, external, unknown
}

public struct ScopedInterfaceSample: Codable, Equatable, Sendable {
    public let counters: InterfaceCounters
    public let scope: NetworkScope
    /// Identity is local and ephemeral; changing it invalidates the attribution interval.
    public let identity: String
    /// Ephemeral source generation (e.g. interface index), not a persistent
    /// device identifier. A change invalidates counter continuity itself.
    public let counterGeneration: String?
    public init(counters: InterfaceCounters, scope: NetworkScope, identity: String, counterGeneration: String? = nil) {
        self.counters = counters
        self.scope = scope
        self.identity = identity
        self.counterGeneration = counterGeneration
    }
    var hasScopeIdentity: Bool {
        !identity.isEmpty && identity.utf8.count <= 4096 &&
        !identity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public struct ScopedTrafficDelta: Equatable, Sendable {
    public let scope: NetworkScope
    public let delta: TrafficDelta
    public init(scope: NetworkScope, delta: TrafficDelta) { self.scope = scope; self.delta = delta }
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
            if let prior = previous[id], prior.counterGeneration != sample.counterGeneration {
                result[id] = invalid
                continue
            }
            let stable = sample.hasScopeIdentity && previous[id]?.hasScopeIdentity == true &&
                         previous[id]?.scope == sample.scope &&
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
            guard group.count == 1, let sample = group.first, sample.hasScopeIdentity else { return .unknown }
            return sample.scope
        }
    }
}

public struct DailyScopeTotals: Equatable, Sendable {
    public let received: UInt64
    public let sent: UInt64
    public init(received: UInt64 = 0, sent: UInt64 = 0) {
        self.received = received; self.sent = sent
    }
}

/// Checked integer accounting. The ceiling preserves lossless v1 compatibility.
public struct DailyTrafficLedger: Equatable, Sendable {
    public static let maximumTotal: UInt64 = 9_007_199_254_740_991
    private var buckets: [NetworkScope: DailyScopeTotals] = [:]
    public private(set) var aggregate = DailyScopeTotals()
    public init() {}
    public func totals(for scope: NetworkScope) -> DailyScopeTotals {
        buckets[scope] ?? DailyScopeTotals()
    }
    @discardableResult
    public mutating func add(scope: NetworkScope, received: UInt64, sent: UInt64) -> Bool {
        let prior = totals(for: scope)
        let (dl, a) = prior.received.addingReportingOverflow(received)
        let (ul, b) = prior.sent.addingReportingOverflow(sent)
        let (allDL, c) = aggregate.received.addingReportingOverflow(received)
        let (allUL, d) = aggregate.sent.addingReportingOverflow(sent)
        let (total, e) = allDL.addingReportingOverflow(allUL)
        guard !a, !b, !c, !d, !e, total <= Self.maximumTotal else { return false }
        buckets[scope] = DailyScopeTotals(received: dl, sent: ul)
        aggregate = DailyScopeTotals(received: allDL, sent: allUL)
        return true
    }
}


/// The caller supplies canonical Gregorian day strings from its local calendar.
/// Do not finalize or reopen a prior day when the wall clock moves backwards.
public enum LocalDayTransition: Equatable, Sendable {
    case unchanged, forward, backward
    public static func evaluate(previous: String, observed: String) -> Self {
        if previous == observed { return .unchanged }
        if previous.isEmpty || observed > previous { return .forward }
        return .backward
    }
}

/// Evidence that a scope has at least one measured interval, not whole-day
/// completeness or provider billing. A measured zero is different from absence.
public struct DailyScopeCoverage: Equatable, Sendable {
    private var scopes = Set<NetworkScope>()
    public init() {}
    public mutating func observe(_ value: ScopedTrafficDelta) {
        guard value.delta.quality == .measured, value.scope != .unknown else { return }
        scopes.insert(value.scope)
    }
    public func observed(_ scope: NetworkScope) -> Bool { scopes.contains(scope) }
    public var persisted: [String] { scopes.map(\.rawValue).sorted() }
    public static func restore(_ raw: [String]) -> Self? {
        guard raw.count <= 3, Set(raw).count == raw.count else { return nil }
        var result = Self()
        for label in raw {
            guard let scope = NetworkScope(rawValue: label), scope != .unknown else { return nil }
            result.scopes.insert(scope)
        }
        return result
    }
}


/// Conservative local scope inference, not provider identity or billing proof.
/// A wired campus prefix is insufficient to identify a dormitory network.
public enum InterfaceScopeEvidence {
    public static func resolve(ipv4: [String], hasUsableIPv6: Bool, isWiFi: Bool,
                               explicit: NetworkScope? = nil) -> NetworkScope {
        var usable: [[UInt8]] = []
        for address in ipv4 {
            let parts = address.split(separator: ".", omittingEmptySubsequences: false)
            let octets = parts.compactMap { part -> UInt8? in
                guard let value = UInt8(part), String(value) == String(part) else { return nil }
                return value
            }
            guard parts.count == 4, octets.count == 4 else { return .unknown }
            guard octets[0] > 0, octets[0] != 127, octets[0] < 224,
                  !(octets[0] == 169 && octets[1] == 254) else { continue }
            usable.append(octets)
        }
        guard !usable.isEmpty || hasUsableIPv6 else { return .unknown }
        if let explicit { return explicit }
        guard !usable.isEmpty else { return .unknown }
        if isWiFi && usable.allSatisfy({ $0[0] == 140 && $0[1] == 120 }) { return .campusWifi }
        if usable.allSatisfy({ $0[0] == 172 && $0[1] == 20 && $0[2] == 10 }) { return .external }
        return .unknown
    }
}


/// A local, in-memory user selection; never a provider identity or permission.
/// Do not persist or transfer this selection to a different network identity.
public struct ManualScopeSelection: Equatable, Sendable {
    public let scope: NetworkScope
    private let interfaceID: String
    private let identity: String
    private let generation: String

    public init?(scope: NetworkScope, sample: ScopedInterfaceSample) {
        guard scope != .unknown, sample.hasScopeIdentity,
              !sample.counters.interfaceID.isEmpty,
              let generation = sample.counterGeneration, !generation.isEmpty,
              generation.utf8.count <= 128,
              !generation.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        self.scope = scope
        self.interfaceID = sample.counters.interfaceID
        self.identity = sample.identity
        self.generation = generation
    }

    public func matches(_ sample: ScopedInterfaceSample) -> Bool {
        sample.hasScopeIdentity && sample.counters.interfaceID == interfaceID &&
        sample.identity == identity && sample.counterGeneration == generation
    }
}
