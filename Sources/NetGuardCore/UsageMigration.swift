import Foundation
import CoreFoundation

public enum UsageMigrationError: Error, Equatable {
    case invalidDocument, unsupportedVersion, invalidDate, invalidCounter
}

public struct DailyUsageState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let date: String
    public let dormIn: UInt64
    public let dormOut: UInt64
    public let wifiIn: UInt64
    public let wifiOut: UInt64
    public let externalIn: UInt64
    public let externalOut: UInt64
    public let unattributedIn: UInt64
    public let unattributedOut: UInt64
    public let sampleGapCount: UInt64
}

/// Decode legacy daily usage without reclassifying traffic or importing raw
/// counter baselines, network settings, addresses or unsafe automation flags.
public enum UsageMigration {
    public static func decode(_ data: Data) throws -> DailyUsageState {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageMigrationError.invalidDocument
        }
        let version = object["schema_version"]
        if version != nil {
            guard let n = version as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == 1 else {
                throw UsageMigrationError.unsupportedVersion
            }
        }
        guard let day = object["date"] as? String,
              day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw UsageMigrationError.invalidDate
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: day), formatter.string(from: parsed) == day else {
            throw UsageMigrationError.invalidDate
        }
        func number(_ key: String, fallback: String? = nil) throws -> UInt64 {
            let value = object[key] ?? fallback.flatMap { object[$0] }
            guard let value else { return 0 }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
                throw UsageMigrationError.invalidCounter
            }
            // Daily byte counts above exact JSON Double integer precision are
            // rejected rather than rounded or silently clipped.
            let d = n.doubleValue
            guard d.isFinite, d >= 0, d <= 9_007_199_254_740_991,
                  d.rounded(.towardZero) == d else { throw UsageMigrationError.invalidCounter }
            return UInt64(d)
        }
        return try DailyUsageState(schemaVersion: 1, date: day,
            dormIn: number("dorm_in", fallback: "today_in"),
            dormOut: number("dorm_out", fallback: "today_out"),
            wifiIn: number("wifi_in"), wifiOut: number("wifi_out"),
            externalIn: number("ext_in"), externalOut: number("ext_out"),
            unattributedIn: number("unattributed_in"), unattributedOut: number("unattributed_out"),
            sampleGapCount: number("sample_gap_count"))
    }
}
