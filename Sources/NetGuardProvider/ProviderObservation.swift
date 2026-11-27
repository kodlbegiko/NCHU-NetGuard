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
              requestedDate == day, day.utf8.count == 10,
              day.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil,
              let stamp = retrievedAt, stamp.utf8.count <= 64,
              stamp.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})\z"#,
                          options: .regularExpression) != nil else { return false }
        let calendarDay = DateFormatter()
        calendarDay.locale = Locale(identifier: "en_US_POSIX")
        calendarDay.calendar = Calendar(identifier: .gregorian)
        calendarDay.timeZone = TimeZone(secondsFromGMT: 0)
        calendarDay.dateFormat = "yyyy-MM-dd"
        calendarDay.isLenient = false
        guard let validDay = calendarDay.date(from: day), calendarDay.string(from: validDay) == day
        else { return false }
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
            default: return "校方資料未知：暫時無法取得"
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
            $0.utf8.count <= 32 && $0.range(of: #"\A[0-9]{1,12}(\.[0-9]{1,6})? *(B|KB|MB|GB|TB)\z"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// A recognized page without our identity is not evidence of safety.
    /// Contradictory ranking fields must not reset the polling backoff.
    func isRecognizedAbsence(for day: String, now: Date) -> Bool {
        status == .notFoundOrUnrecognized && errorCode == .notListed &&
        rank == nil && downloadDisplay == nil && uploadDisplay == nil && totalDisplay == nil &&
        unitsVerified != true && isFresh(for: day, now: now)
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
    public var isInFlight: Bool { active != nil }
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
        // Failure still consumes service resources, even if a route change
        // invalidated the response. Only a current success may reset backoff.
        if !usable { delay = min(600, delay * 2) }
        else if current { delay = 60 }
        return current
    }
}


/// Explicit adapter evidence, never derived from a formatted ranking.
public struct ComparableUsageObservation: Equatable, Sendable {
    public enum Origin: String, Sendable { case local, provider }
    public let origin: Origin
    // Opaque, ephemeral tokens supplied by an independent identity/boundary
    // verifier. These must not contain a raw address or account identifier.
    public let verifiedIdentity: UUID?
    public let verifiedBoundary: UUID?
    public let windowStart: Date?
    public let windowEnd: Date?
    public let retrievedAt: Date?
    public let verifiedByteUnits: Bool
    public let completeWindow: Bool
    public let received: UInt64?
    public let sent: UInt64?

    public init(origin: Origin, verifiedIdentity: UUID?, verifiedBoundary: UUID?,
                windowStart: Date?, windowEnd: Date?, retrievedAt: Date?,
                verifiedByteUnits: Bool, completeWindow: Bool,
                received: UInt64?, sent: UInt64?) {
        self.origin = origin
        self.verifiedIdentity = verifiedIdentity; self.verifiedBoundary = verifiedBoundary
        self.windowStart = windowStart; self.windowEnd = windowEnd; self.retrievedAt = retrievedAt
        self.verifiedByteUnits = verifiedByteUnits; self.completeWindow = completeWindow
        self.received = received; self.sent = sent
    }
}

public enum ProviderComparisonFailure: String, Equatable, Sendable {
    case invalidSources, identityUnverified, boundaryUnverified, unitsUnverified,
         windowUnverified, incompleteWindow, staleObservation, missingCounters
}

public struct DirectionalUsageDifference: Equatable, Sendable {
    public enum Direction: String, Sendable { case equal, localHigher, providerHigher }
    public let direction: Direction
    public let bytes: UInt64
    fileprivate init(local: UInt64, provider: UInt64) {
        direction = local == provider ? .equal : (local > provider ? .localHigher : .providerHigher)
        bytes = local >= provider ? local - provider : provider - local
    }
}

public enum ProviderComparison: Equatable, Sendable {
    case unavailable(ProviderComparisonFailure)
    case comparable(download: DirectionalUsageDifference, upload: DirectionalUsageDifference)
}

/// No source authentication is established by constructing these values.
/// The live NCHU ranking cannot satisfy these requirements yet. Never sum
/// local and provider observations, or turn this difference into a balance.
public enum ProviderReconciler {
    public static func compare(local: ComparableUsageObservation, provider: ComparableUsageObservation,
                               now: Date, maxAge: TimeInterval = 600) -> ProviderComparison {
        guard local.origin == .local, provider.origin == .provider else { return .unavailable(.invalidSources) }
        guard let identity = local.verifiedIdentity, provider.verifiedIdentity == identity else {
            return .unavailable(.identityUnverified)
        }
        guard let boundary = local.verifiedBoundary, provider.verifiedBoundary == boundary else {
            return .unavailable(.boundaryUnverified)
        }
        guard local.verifiedByteUnits, provider.verifiedByteUnits else { return .unavailable(.unitsUnverified) }
        guard let start = local.windowStart, let end = local.windowEnd,
              start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              start < end, provider.windowStart == start, provider.windowEnd == end else {
            return .unavailable(.windowUnverified)
        }
        guard local.completeWindow, provider.completeWindow else { return .unavailable(.incompleteWindow) }
        guard maxAge.isFinite, maxAge >= 0, now.timeIntervalSinceReferenceDate.isFinite,
              end <= now, now.timeIntervalSince(end) <= maxAge,
              [local, provider].allSatisfy({ value in
                  guard let retrieved = value.retrievedAt, retrieved.timeIntervalSinceReferenceDate.isFinite,
                        retrieved >= end, retrieved <= now else { return false }
                  return now.timeIntervalSince(retrieved) <= maxAge
              }) else { return .unavailable(.staleObservation) }
        guard let ld = local.received, let lu = local.sent,
              let pd = provider.received, let pu = provider.sent else { return .unavailable(.missingCounters) }
        return .comparable(download: .init(local: ld, provider: pd), upload: .init(local: lu, provider: pu))
    }
}
