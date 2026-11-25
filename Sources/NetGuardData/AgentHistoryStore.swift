import Foundation

/// Dedicated local history. Only fixed AI workload labels may be persisted.
/// These measurements overlap the general process history; never add them.
public struct AgentHistoryStore: Sendable {
    private let store: ProcessHistoryStore
    public init(directory: URL) { store = ProcessHistoryStore(directory: directory) }
    public static let allowedLabels: Set<String> = ["Codex", "Claude / Claude Code", "Cursor", "Ollama", "LM Studio"]

    private func validate(_ buckets: [ProcessHistoryBucket]) throws {
        guard buckets.allSatisfy({ $0.rows.allSatisfy { Self.allowedLabels.contains($0.name) } })
        else { throw HistoryStoreError.invalidRecord }
    }

    public func save(day: String, bucket: ProcessHistoryBucket) throws {
        try validate([bucket])
        try validate(store.read(day: day).buckets)
        try store.save(day: day, bucket: bucket)
    }

    public func readRecent(now: Date = Date()) throws -> [ProcessHistoryDay] {
        guard now.timeIntervalSince1970.isFinite else { throw HistoryStoreError.invalidRecord }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return try (0..<7).map { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { throw HistoryStoreError.invalidRecord }
            let day = try store.read(day: ProcessHistoryStore.hour(at: date).day)
            try validate(day.buckets)
            return day
        }
    }

    @discardableResult public func prune(now: Date = Date()) throws -> Int {
        try store.prune(keepingDays: 30, now: now)
    }
    @discardableResult public func removeAll() throws -> Int { try store.removeAllHistory() }
}
