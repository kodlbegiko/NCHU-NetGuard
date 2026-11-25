import Foundation

public struct AppTrafficObservation: Equatable, Sendable {
    public let name: String
    public let bytes: UInt64
    public init(name: String, bytes: UInt64) { self.name = name; self.bytes = bytes }
}

public enum AppTrafficParser {
    /// One nettop snapshot of process-lifetime counters. Not a daily total or
    /// per-interface attribution. Unrecognized rows are excluded, never guessed.
    public static func parse(_ output: String) -> [AppTrafficObservation] {
        var byName: [String: UInt64] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3, let rx = UInt64(parts[1].trimmingCharacters(in: .whitespaces)),
                  let tx = UInt64(parts[2].trimmingCharacters(in: .whitespaces)) else { continue }
            let raw = parts[0].trimmingCharacters(in: .whitespaces)
            let name = raw.replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
            guard !name.isEmpty, name.count <= 128,
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { continue }
            let (total, overflow) = rx.addingReportingOverflow(tx)
            let (sum, aggregateOverflow) = (byName[name] ?? 0).addingReportingOverflow(total)
            guard !overflow, !aggregateOverflow else { continue }
            byName[name] = sum
        }
        return byName.map { AppTrafficObservation(name: $0.key, bytes: $0.value) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
    }
}
