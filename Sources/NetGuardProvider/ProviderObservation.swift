import Foundation

public enum ProviderStatus: String, Codable, Sendable {
    case listed, notFoundOrUnrecognized = "not_found_or_unrecognized", unavailable,
         notApplicable = "not_applicable", invalidIdentity = "invalid_identity"
}

public enum ProviderErrorCode: String, Codable, Sendable {
    case invalidIdentity = "invalid_identity", responseLimit = "response_limit",
         ambiguousIdentity = "ambiguous_identity", notListed = "not_listed",
         unrecognizedRanking = "unrecognized_ranking", malformedRow = "malformed_row",
         unexpectedResponse = "unexpected_response", invalidEncoding = "invalid_encoding",
         rateLimited = "rate_limited", redirectRejected = "redirect_rejected",
         httpError = "http_error", tlsError = "tls_error", timeout,
         networkError = "network_error"
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
    public let errorCode: ProviderErrorCode?

    public init(status: ProviderStatus, requestedDate: String?, retrievedAt: String?, rank: Int?, downloadDisplay: String?, uploadDisplay: String?, totalDisplay: String?, unitsVerified: Bool?, errorCode: ProviderErrorCode? = nil) {
        self.status = status; self.requestedDate = requestedDate; self.retrievedAt = retrievedAt; self.rank = rank
        self.downloadDisplay = downloadDisplay; self.uploadDisplay = uploadDisplay; self.totalDisplay = totalDisplay; self.unitsVerified = unitsVerified; self.errorCode = errorCode
    }

    enum CodingKeys: String, CodingKey {
        case status, rank
        case errorCode = "error_code"
        case requestedDate = "requested_date"
        case retrievedAt = "retrieved_at"
        case downloadDisplay = "download_display"
        case uploadDisplay = "upload_display"
        case totalDisplay = "total_display"
        case unitsVerified = "units_verified"
    }

    public func isFresh(for day: String, now: Date, maxAge: TimeInterval = 600) -> Bool {
        guard maxAge.isFinite, maxAge >= 0, now.timeIntervalSinceReferenceDate.isFinite,
              requestedDate == day, day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              let stamp = retrievedAt, stamp.utf8.count <= 64 else { return false }
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
        if status == .unavailable {
            switch errorCode {
            case .tlsError: return "校方資料未知：TLS 驗證失敗"
            case .rateLimited: return "校方資料未知：服務限流"
            case .timeout: return "校方資料未知：請求逾時"
            default: return "校方資料暫時無法取得"
            }
        }
        guard isFresh(for: day, now: now) else { return "校方資料未知或已過期" }
        guard isUsableRanking(for: day, now: now), let rank,
              let downloadDisplay, let uploadDisplay else { return "校方榜單未確認，不能判定安全" }
        return "校方榜單第 \(rank) 名 · 下 \(downloadDisplay) / 上 \(uploadDisplay)（單位與更新時間未驗證）"
    }
}


public extension ProviderObservation {
    /// Fresh retrieval is not proof of billing freshness. All diagnostic
    /// consumers must use this stricter predicate instead of status alone.
    func isUsableRanking(for day: String, now: Date) -> Bool {
        guard isFresh(for: day, now: now), status == .listed, errorCode == nil, let rank,
              (1...999_999).contains(rank), unitsVerified == false,
              let downloadDisplay, let uploadDisplay, let totalDisplay else { return false }
        return [downloadDisplay, uploadDisplay, totalDisplay].allSatisfy {
            $0.utf8.count <= 32 && $0.range(of: #"^[0-9]{1,12}(\.[0-9]{1,6})? *(B|KB|MB|GB|TB)$"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

/// Single-flight monotonic request scheduling. Invalidation rejects a stale
/// result without releasing the physical request slot or resetting rate limits.
/// No persistent identity, network I/O or sleeping in this pure value type.
public struct ProviderPollGate: Sendable {
    private var active: UUID?
    private var invalidated = false
    private var lastStart: TimeInterval?
    private var delay: TimeInterval = 60
    public init() {}
    public mutating func begin(at uptime: TimeInterval) -> UUID? {
        guard uptime.isFinite, uptime >= 0, active == nil else { return nil }
        if let lastStart {
            guard uptime >= lastStart, uptime - lastStart >= delay else { return nil }
        }
        let request = UUID()
        active = request
        lastStart = uptime
        invalidated = false
        return request
    }
    public mutating func invalidate() {
        if active != nil { invalidated = true }
    }
    /// A successful completion of a still-current request resets the backoff.
    /// A failure doubles the delay to a capped 10 minutes. Invalidation does
    /// not erase prior backoff and never permits an overlapping request.
    @discardableResult
    public mutating func finish(_ request: UUID, usable: Bool) -> Bool {
        guard active == request else { return false }
        active = nil
        let current = !invalidated
        invalidated = false
        if current { delay = usable ? 60 : min(600, delay * 2) }
        return current
    }
}
