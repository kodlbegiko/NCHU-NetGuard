import Foundation

public enum HistoryChartKind: String, Equatable, Sendable {
    case download, upload, directionUnknown, missing, recordedZero
}

public struct HistoryChartPoint: Equatable, Sendable, Identifiable {
    public let day: String
    public let kind: HistoryChartKind
    public let bytes: UInt64
    public var id: String { day + ":" + kind.rawValue }
}

public extension HistoryPeriod {
    /// Missing days and actual zeroes have different marker types. A legacy
    /// total is not split into invented directional values.
    var chartPoints: [HistoryChartPoint] {
        rows.flatMap { row -> [HistoryChartPoint] in
            guard let record = row.record else {
                return [.init(day: row.day, kind: .missing, bytes: 0)]
            }
            guard record.total > 0 else {
                return [.init(day: row.day, kind: record.download == nil ? .directionUnknown : .recordedZero, bytes: 0)]
            }
            if let download = record.download, let upload = record.upload {
                return [.init(day: row.day, kind: .download, bytes: download),
                        .init(day: row.day, kind: .upload, bytes: upload)].filter { $0.bytes > 0 }
            }
            return [.init(day: row.day, kind: .directionUnknown, bytes: record.total)]
        }
    }
}
