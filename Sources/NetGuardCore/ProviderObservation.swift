import Foundation

public enum ProviderStatus: String, Codable, Sendable {
    case listed, notFoundOrUnrecognized = "not_found_or_unrecognized", unavailable,
         notApplicable = "not_applicable", invalidIdentity = "invalid_identity"
}

public struct ProviderObservation: Codable, Equatable, Sendable {
    public let status: ProviderStatus
    public let requestedDate: String?
    public let retrievedAt: String?
    public let rank: Int?
    public let downloadDisplay: String?
    public let uploadDisplay: String?
    public let totalDisplay: String?
    public let unitsVerified: Bool?

    enum CodingKeys: String, CodingKey {
        case status, rank
        case requestedDate = "requested_date"
        case retrievedAt = "retrieved_at"
        case downloadDisplay = "download_display"
        case uploadDisplay = "upload_display"
        case totalDisplay = "total_display"
        case unitsVerified = "units_verified"
    }

    public func isFresh(for day: String, now: Date, maxAge: TimeInterval = 600) -> Bool {
        guard requestedDate == day, let stamp = retrievedAt else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        guard let date = fractional.date(from: stamp) ?? standard.date(from: stamp) else { return false }
        let age = now.timeIntervalSince(date)
        return age >= -5 && age <= maxAge
    }

    /// The ranking source provides no verified billing unit or measurement timestamp.
    /// A fresh HTTP response must not be mistaken for fresh accounting data.
    public func displayStatus(for day: String, now: Date) -> String {
        guard isFresh(for: day, now: now) else { return "校方資料未知或已過期" }
        guard status == .listed, let rank, rank > 0,
              let downloadDisplay, let uploadDisplay, let totalDisplay,
              unitsVerified == false,
              [downloadDisplay, uploadDisplay, totalDisplay].allSatisfy({
                  $0.range(of: #"^[0-9]{1,12}(\.[0-9]{1,6})?\s*(B|KB|MB|GB|TB)$"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
              }) else { return "校方榜單未確認，不能判定安全" }
        return "校方榜單第 \(rank) 名 · 下 \(downloadDisplay) / 上 \(uploadDisplay)（單位與更新時間未驗證）"
    }
}
