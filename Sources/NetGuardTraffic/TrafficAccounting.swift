import Foundation

/// Version 1 contracts. Pure accounting; never changes system state.
public enum SampleQuality: String, Codable, Sendable {
    case measured, estimated, unknown, stale
}

public struct InterfaceCounters: Codable, Equatable, Sendable {
    public let interfaceID: String
    public let received: UInt64
    public let sent: UInt64
    public init(interfaceID: String, received: UInt64, sent: UInt64) {
        self.interfaceID = interfaceID
        self.received = received
        self.sent = sent
    }
}

public struct TrafficDelta: Codable, Equatable, Sendable {
    public let received: UInt64
    public let sent: UInt64
    public let quality: SampleQuality
    public init(received: UInt64, sent: UInt64, quality: SampleQuality) {
        self.received = received; self.sent = sent; self.quality = quality
    }
}

public struct TrafficSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let interfaces: [InterfaceCounters]
    public let quality: SampleQuality
    public init(timestamp: Date, interfaces: [InterfaceCounters], quality: SampleQuality) {
        self.schemaVersion = 1
        self.timestamp = timestamp
        self.interfaces = interfaces
        self.quality = quality
    }
}

/// One accumulator per sampling source. Missing devices lose their baseline;
/// reset/wrap cannot be distinguished reliably, so the affected sample is unknown.
public struct CounterAccumulator: Sendable {
    private var previous: [String: InterfaceCounters] = [:]
    public init() {}
    public mutating func ingest(_ counters: [InterfaceCounters]) -> [String: TrafficDelta] {
        var next: [String: InterfaceCounters] = [:]
        var result: [String: TrafficDelta] = [:]
        var duplicates = Set<String>()
        for current in counters {
            let id = current.interfaceID
            if next[id] != nil {
                duplicates.insert(id)
                result[id] = TrafficDelta(received: 0, sent: 0, quality: .unknown)
                continue
            }
            next[id] = current
            guard let old = previous[id],
                  current.received >= old.received, current.sent >= old.sent else {
                result[id] = TrafficDelta(received: 0, sent: 0, quality: .unknown)
                continue
            }
            result[id] = TrafficDelta(received: current.received - old.received,
                                      sent: current.sent - old.sent, quality: .measured)
        }
        for id in duplicates { next.removeValue(forKey: id) }
        previous = next
        return result
    }
}
