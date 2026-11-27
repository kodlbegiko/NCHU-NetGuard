import Foundation

public struct ConnectionSessionReading: Equatable, Sendable {
    public let label: String
    public let received: UInt64
    public let sent: UInt64
    public let limitBytes: UInt64
    public let intervals: Int
    public let stopped: Bool
    public var total: UInt64 { received + sent }
    public var remaining: UInt64 { total >= limitBytes ? 0 : limitBytes - total }
}

/// Explicitly started, in-memory connection session, NOT a persistent network
/// identity. Network changes or ambiguous observations permanently stop it.
/// This is a subset of physical interface traffic, not a separate billing total.
public struct ConnectionSessionMeter: Sendable {
    private var label: String?
    private var interface: String?
    private var identity: String?
    private var counterGeneration: String?
    private var scope: NetworkScope?
    private var limit: UInt64 = 0
    private var received: UInt64 = 0
    private var sent: UInt64 = 0
    private var intervals = 0
    private var stopped = true

    public init() {}
    public mutating func begin(label: String, gigabytes: UInt64, sample: ScopedInterfaceSample) -> Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...10_000).contains(gigabytes), sample.hasScopeIdentity,
              sample.hasValidCounterIdentity else { return false }
        self.label = name
        interface = sample.counters.interfaceID
        identity = sample.identity
        counterGeneration = sample.counterGeneration
        scope = sample.scope
        limit = gigabytes * 1_000_000_000
        received = 0; sent = 0; intervals = 0; stopped = false
        return true
    }
    public mutating func stop() { stopped = true }
    public mutating func clear() { self = Self() }

    public mutating func ingest(samples: [ScopedInterfaceSample], deltas: [String: ScopedTrafficDelta],
                                currentInterface: String, connectionKnown: Bool) {
        guard !stopped, let interface, let identity else { return }
        let matching = samples.filter { $0.counters.interfaceID == interface }
        guard connectionKnown, currentInterface == interface, matching.count == 1,
              matching[0].hasScopeIdentity, matching[0].hasValidCounterIdentity,
              matching[0].identity == identity, matching[0].scope == scope,
              matching[0].counterGeneration == counterGeneration,
              let value = deltas[interface], value.delta.quality == .measured,
              value.scope == matching[0].scope else { stop(); return }
        // The first delta may have started before the user pressed Start.
        // Drop it, including its bytes, rather than overstate session usage.
        if intervals == 0 { intervals = 1; return }
        let (rx, a) = received.addingReportingOverflow(value.delta.received)
        let (tx, b) = sent.addingReportingOverflow(value.delta.sent)
        let (_, c) = rx.addingReportingOverflow(tx)
        guard !a, !b, !c, intervals < Int.max else { stop(); return }
        received = rx; sent = tx; intervals += 1
    }
    public func reading() -> ConnectionSessionReading? {
        guard let label else { return nil }
        return .init(label: label, received: received, sent: sent, limitBytes: limit,
                     intervals: max(0, intervals - 1), stopped: stopped)
    }
}
