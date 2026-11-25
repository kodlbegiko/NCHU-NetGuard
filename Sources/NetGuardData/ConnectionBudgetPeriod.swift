import Foundation

/// User-selected archive records, filtered by save date, not verified billing dates.
public struct ConnectionBudgetPeriod: Equatable, Sendable {
    public let startDay: String
    public let endDay: String // inclusive
    public let limitBytes: UInt64

    public init(startDay: String, endDay: String, decimalGB: UInt64) throws {
        _ = try HistoryDay(day: startDay, total: 0, download: nil, upload: nil)
        _ = try HistoryDay(day: endDay, total: 0, download: nil, upload: nil)
        guard startDay <= endDay, (1...10_000).contains(decimalGB) else { throw HistoryStoreError.invalidRecord }
        self.startDay = startDay; self.endDay = endDay; limitBytes = decimalGB * 1_000_000_000
    }

    /// Billing anchor 1...31, clamped to the last day of shorter months.
    /// Uses Taipei calendar days and inclusive end date; no fixed 30-day approximation.
    public static func monthly(at date: Date, anchorDay: Int, decimalGB: UInt64) throws -> Self {
        guard (1...31).contains(anchorDay), date.timeIntervalSince1970.isFinite else {
            throw HistoryStoreError.invalidRecord
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        guard let month = calendar.dateInterval(of: .month, for: date)?.start else { throw HistoryStoreError.invalidRecord }
        func anchor(_ monthStart: Date) throws -> Date {
            guard let days = calendar.range(of: .day, in: .month, for: monthStart),
                  let value = calendar.date(byAdding: .day, value: min(anchorDay, days.count) - 1, to: monthStart)
            else { throw HistoryStoreError.invalidRecord }
            return value
        }
        let current = try anchor(month)
        let startMonth: Date
        if date < current {
            guard let previous = calendar.date(byAdding: .month, value: -1, to: month) else { throw HistoryStoreError.invalidRecord }
            startMonth = previous
        } else { startMonth = month }
        guard let next = calendar.date(byAdding: .month, value: 1, to: startMonth) else { throw HistoryStoreError.invalidRecord }
        let start = try anchor(startMonth)
        guard let end = calendar.date(byAdding: .day, value: -1, to: anchor(next)) else { throw HistoryStoreError.invalidRecord }
        return try Self(startDay: ProcessHistoryStore.hour(at: start).day, endDay: ProcessHistoryStore.hour(at: end).day, decimalGB: decimalGB)
    }

    public func includes(_ row: SavedConnectionSession) -> Bool {
        let day = ProcessHistoryStore.hour(at: row.savedAt).day
        return startDay <= day && day <= endDay
    }

    public func summarize(records: [SavedConnectionSession], selected: Set<UUID>) throws -> ConnectionCycleReading? {
        guard records.count <= 1000, Set(records.map(\.id)).count == records.count else { throw HistoryStoreError.invalidRecord }
        let chosen = records.filter { selected.contains($0.id) }
        guard chosen.count == selected.count, chosen.allSatisfy({ includes($0) }) else { throw HistoryStoreError.invalidRecord }
        guard !chosen.isEmpty else { return nil }
        var received: UInt64 = 0, sent: UInt64 = 0
        for row in chosen {
            _ = try SavedConnectionSession(id: row.id, label: row.label, savedAt: row.savedAt, received: row.received,
                sent: row.sent, limitBytes: row.limitBytes, intervals: row.intervals)
            let (rx, a) = received.addingReportingOverflow(row.received)
            let (tx, b) = sent.addingReportingOverflow(row.sent)
            let (_, c) = rx.addingReportingOverflow(tx)
            guard !a, !b, !c else { throw HistoryStoreError.invalidRecord }
            received = rx; sent = tx
        }
        return .init(received: received, sent: sent, limitBytes: limitBytes, recordCount: chosen.count)
    }
}

public struct ConnectionCycleReading: Equatable, Sendable {
    public let received: UInt64
    public let sent: UInt64
    public let limitBytes: UInt64
    public let recordCount: Int
    public var total: UInt64 { received + sent }
    public var remaining: UInt64 { total >= limitBytes ? 0 : limitBytes - total }
}
