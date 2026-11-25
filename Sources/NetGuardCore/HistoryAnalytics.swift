import Foundation

public struct HistoryPeriodDay: Equatable, Sendable, Identifiable {
    public let day: String
    public let record: HistoryDay?
    public var id: String { day }
}

public struct HistoryPeriod: Equatable, Sendable {
    public let rows: [HistoryPeriodDay]
    public var recordedDays: Int { rows.filter { $0.record != nil }.count }
    public var averageBytes: Double? {
        let values = rows.compactMap { $0.record?.total }
        guard !values.isEmpty else { return nil }
        return values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
    }

    /// CSV includes absent days and preserves unknown directional fields.
    /// All values are validated dates, integers, or fixed status literals.
    public func csv(scope: NetworkScope? = nil) -> String {
        var lines = ["date,total_bytes,download_bytes,upload_bytes,status"]
        for row in rows {
            if let r = row.record {
                lines.append([row.day, String(r.total), r.download.map { String($0) } ?? "",
                              r.upload.map { String($0) } ?? "",
                              r.download == nil ? "direction_unknown" : "recorded"].joined(separator: ","))
            } else {
                lines.append(row.day + ",,,,missing")
            }
        }
        if let scope {
            lines[0] += ",scope"
            for index in lines.indices.dropFirst() { lines[index] += "," + scope.rawValue }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

public enum HistoryAnalytics {
    /// Completed Taiwan calendar days only. Missing days are not assumed zero.
    public static func period(endingBefore today: String, days: Int,
                              records: [HistoryDay]) throws -> HistoryPeriod {
        guard (1...366).contains(days), let zone = TimeZone(identifier: "Asia/Taipei")
        else { throw HistoryStoreError.invalidRecord }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let end = formatter.date(from: today), formatter.string(from: end) == today
        else { throw HistoryStoreError.invalidRecord }
        var indexed: [String: HistoryDay] = [:]
        for record in records {
            _ = try HistoryDay(day: record.day, total: record.total,
                               download: record.download, upload: record.upload)
            guard indexed.updateValue(record, forKey: record.day) == nil
            else { throw HistoryStoreError.invalidRecord }
        }
        var rows: [HistoryPeriodDay] = []
        for offset in (1...days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end)
            else { throw HistoryStoreError.invalidRecord }
            let day = formatter.string(from: date)
            rows.append(HistoryPeriodDay(day: day, record: indexed[day]))
        }
        return HistoryPeriod(rows: rows)
    }
}
