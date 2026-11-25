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

    public func storedDays() throws -> [String] { try store.storedDays() }

    public func read(day: String) throws -> ProcessHistoryDay {
        let result = try store.read(day: day)
        try validate(result.buckets)
        return result
    }

    public func readRecent(now: Date = Date()) throws -> [ProcessHistoryDay] {
        guard now.timeIntervalSince1970.isFinite else { throw HistoryStoreError.invalidRecord }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return try (0..<7).map { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { throw HistoryStoreError.invalidRecord }
            return try read(day: ProcessHistoryStore.hour(at: date).day)
        }
    }

    @discardableResult public func prune(now: Date = Date()) throws -> Int {
        try store.prune(keepingDays: 30, now: now)
    }
    @discardableResult public func removeAll() throws -> Int { try store.removeAllHistory() }
}


public struct AgentTrendDay: Equatable, Sendable, Identifiable {
    public let day: String
    public let rows: [ProcessHistoryRow]
    public let hasObservation: Bool
    public let limited: Bool
    public let download: UInt64
    public let upload: UInt64
    public var id: String { day }
    public var total: UInt64 { download + upload }
}

public struct AgentTrend: Equatable, Sendable {
    public let days: [AgentTrendDay]
    public let ranking: [ProcessHistoryRow]
    public var observedDays: Int { days.filter(\.hasObservation).count }
}

public enum AgentHistoryAnalytics {
    /// Absence is not measured zero. Rankings sum only observed rows,
    /// and are not a comparison of complete-day resource consumption.
    public static func summarize(_ input: [ProcessHistoryDay]) throws -> AgentTrend {
        guard input.count <= 7, Set(input.map(\.day)).count == input.count else {
            throw HistoryStoreError.invalidRecord
        }
        var all: [String: ProcessHistoryRow] = [:]
        var days: [AgentTrendDay] = []
        for day in input.sorted(by: { $0.day < $1.day }) {
            _ = try HistoryDay(day: day.day, total: 0, download: nil, upload: nil)
            let rows = try day.totals()
            var dl: UInt64 = 0, ul: UInt64 = 0
            for row in rows {
                guard AgentHistoryStore.allowedLabels.contains(row.name) else { throw HistoryStoreError.invalidRecord }
                let (d, a) = dl.addingReportingOverflow(row.download)
                let (u, b) = ul.addingReportingOverflow(row.upload)
                guard !a, !b, !d.addingReportingOverflow(u).overflow else { throw HistoryStoreError.invalidRecord }
                dl = d; ul = u
                let (rd, c) = (all[row.name]?.download ?? 0).addingReportingOverflow(row.download)
                let (ru, e) = (all[row.name]?.upload ?? 0).addingReportingOverflow(row.upload)
                guard !c, !e else { throw HistoryStoreError.invalidRecord }
                all[row.name] = try ProcessHistoryRow(name: row.name, download: rd, upload: ru)
            }
            days.append(.init(day: day.day, rows: rows, hasObservation: !day.buckets.isEmpty,
                limited: day.limited, download: dl, upload: ul))
        }
        return .init(days: days, ranking: all.values.sorted { $0.total == $1.total ? $0.name < $1.name : $0.total > $1.total })
    }
}
