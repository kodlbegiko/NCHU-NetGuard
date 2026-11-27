import Foundation
import XCTest
import NetGuardProvider

final class ProviderModuleTests: XCTestCase {
    func testInvalidFreshnessWindowFailsClosed() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z"))
        let observation = ProviderObservation(status: .listed, requestedDate: "2026-11-25",
            retrievedAt: "2026-11-25T12:00:00Z", rank: 1, downloadDisplay: "1 GB",
            uploadDisplay: "1 GB", totalDisplay: "2 GB", unitsVerified: false)
        for age in [Double.nan, Double.infinity, -1] {
            XCTAssertFalse(observation.isFresh(for: "2026-11-25", now: now, maxAge: age))
        }
    }
    func testSingleFlightAndBackoffSurviveInvalidation() throws {
        var gate = ProviderPollGate()
        let first = try XCTUnwrap(gate.begin(at: 0))
        gate.invalidate()
        XCTAssertNil(gate.begin(at: 100))
        XCTAssertFalse(gate.finish(UUID(), usable: true))
        XCTAssertFalse(gate.finish(first, usable: true))
        XCTAssertNil(gate.begin(at: 59))
        let second = try XCTUnwrap(gate.begin(at: 60))
        XCTAssertTrue(gate.finish(second, usable: false))
        XCTAssertNil(gate.begin(at: 179))
        let third = try XCTUnwrap(gate.begin(at: 180))
        XCTAssertTrue(gate.finish(third, usable: true))
        XCTAssertNil(gate.begin(at: 239))
        XCTAssertNotNil(gate.begin(at: 240))
    }
    func testInvalidatedFailureStillBacksOff() throws {
        var gate = ProviderPollGate()
        let first = try XCTUnwrap(gate.begin(at: 0))
        gate.invalidate()
        XCTAssertFalse(gate.finish(first, usable: false))
        XCTAssertNil(gate.begin(at: 119))
        let second = try XCTUnwrap(gate.begin(at: 120))
        gate.invalidate()
        XCTAssertFalse(gate.finish(second, usable: true))
        XCTAssertNil(gate.begin(at: 239))
        XCTAssertNotNil(gate.begin(at: 240))
    }
    func testInvalidCalendarDayNeverFresh() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z"))
        let observation = ProviderObservation(status: .listed, requestedDate: "2026-02-30",
            retrievedAt: "2026-11-25T12:00:00Z", rank: 1, downloadDisplay: "1 GB",
            uploadDisplay: "1 GB", totalDisplay: "2 GB", unitsVerified: false)
        XCTAssertFalse(observation.isFresh(for: "2026-02-30", now: now))
    }
    func testReconciliationRequiresComparableEvidenceAndPreservesIntegerDifference() {
        let start = Date(timeIntervalSince1970: 100), end = Date(timeIntervalSince1970: 200)
        let now = Date(timeIntervalSince1970: 210)
        let identity = UUID(), boundary = UUID()
        func observation(_ origin: ComparableUsageObservation.Origin, identity: UUID?,
                         boundary: UUID?, units: Bool = true, complete: Bool = true,
                         endTime: Date? = nil, down: UInt64? = 0, up: UInt64? = 0) -> ComparableUsageObservation {
            .init(origin: origin, verifiedIdentity: identity, verifiedBoundary: boundary,
                  windowStart: start, windowEnd: endTime ?? end, retrievedAt: endTime ?? end,
                  verifiedByteUnits: units, completeWindow: complete, received: down, sent: up)
        }
        let local = observation(.local, identity: identity, boundary: boundary, down: UInt64.max, up: 0)
        let provider = observation(.provider, identity: identity, boundary: boundary, down: 0, up: 10)
        if case .comparable(let dl, let ul) = ProviderReconciler.compare(local: local, provider: provider, now: now) {
            XCTAssertEqual(dl.direction, .localHigher)
            XCTAssertEqual(dl.bytes, UInt64.max)
            XCTAssertEqual(ul.direction, .providerHigher)
            XCTAssertEqual(ul.bytes, 10)
        } else { XCTFail("expected comparable evidence") }
        let cases: [(ComparableUsageObservation, ProviderComparisonFailure)] = [
            (observation(.local, identity: identity, boundary: boundary), .invalidSources),
            (observation(.provider, identity: nil, boundary: boundary), .identityUnverified),
            (observation(.provider, identity: UUID(), boundary: boundary), .identityUnverified),
            (observation(.provider, identity: identity, boundary: UUID()), .boundaryUnverified),
            (observation(.provider, identity: identity, boundary: boundary, units: false), .unitsUnverified),
            (observation(.provider, identity: identity, boundary: boundary, complete: false), .incompleteWindow),
            (observation(.provider, identity: identity, boundary: boundary, endTime: now), .windowUnverified),
            (observation(.provider, identity: identity, boundary: boundary, down: nil), .missingCounters)
        ]
        for (value, reason) in cases {
            XCTAssertEqual(ProviderReconciler.compare(local: local, provider: value, now: now), .unavailable(reason))
        }
        XCTAssertEqual(ProviderReconciler.compare(local: local, provider: provider, now: now, maxAge: 5),
                       .unavailable(.staleObservation))
        XCTAssertEqual(ProviderReconciler.compare(local: local, provider: provider, now: now, maxAge: .nan),
                       .unavailable(.staleObservation))
    }
    func testInvalidRankingNeverCountsAsUsable() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z"))
        for (rank, text, units) in [(0, "1 GB", false), (1, "1\nGB", false), (1, "1 GB", true), (1, String(repeating: "9", count: 100), false)] {
            let observation = ProviderObservation(status: .listed, requestedDate: "2026-11-25",
                retrievedAt: "2026-11-25T12:00:00Z", rank: rank, downloadDisplay: text,
                uploadDisplay: "1 GB", totalDisplay: "2 GB", unitsVerified: units)
            XCTAssertFalse(observation.isUsableRanking(for: "2026-11-25", now: now))
        }
    }
    func testRankingRequiresWholeFieldMatchAndCanonicalTimestamp() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z"))
        func observation(_ download: String, _ stamp: String = "2026-11-25T12:00:00Z") -> ProviderObservation {
            .init(status: .listed, requestedDate: "2026-11-25", retrievedAt: stamp,
                  rank: 1, downloadDisplay: download, uploadDisplay: "1 GB",
                  totalDisplay: "2 GB", unitsVerified: false)
        }
        for text in ["1 GB\n", "1 GB\r\n", "1 GB\u{0000}", "1 GB\u{2028}", "1 GB\u{2029}"] {
            XCTAssertFalse(observation(text).isUsableRanking(for: "2026-11-25", now: now))
        }
        for stamp in ["2026-11-25T12:00:00Z\n", "2026-11-25T12:00:00Zsuffix", "2026-11-25T12:00:00"] {
            XCTAssertFalse(observation("1 GB", stamp).isFresh(for: "2026-11-25", now: now))
        }
        XCTAssertTrue(observation("1 GB").isUsableRanking(for: "2026-11-25", now: now))
        XCTAssertTrue(observation("1 GB", "2026-11-25T12:00:00.123456+00:00")
            .isUsableRanking(for: "2026-11-25", now: now))
    }

    func testOnlyUncontradictedRecognizedAbsenceCanResetBackoff() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z"))
        func observation(rank: Int? = nil, download: String? = nil, upload: String? = nil,
                         total: String? = nil, units: Bool? = nil,
                         error: ProviderErrorCode = .notListed) -> ProviderObservation {
            .init(status: .notFoundOrUnrecognized, requestedDate: "2026-11-25",
                  retrievedAt: "2026-11-25T12:00:00Z", rank: rank,
                  downloadDisplay: download, uploadDisplay: upload, totalDisplay: total,
                  unitsVerified: units, errorCode: error)
        }
        XCTAssertTrue(observation().isRecognizedAbsence(for: "2026-11-25", now: now))
        XCTAssertTrue(observation(units: false).isRecognizedAbsence(for: "2026-11-25", now: now))
        for value in [observation(rank: 1), observation(download: "1 GB"),
                      observation(upload: "1 GB"), observation(total: "1 GB"),
                      observation(units: true), observation(error: .malformedRow)] {
            XCTAssertFalse(value.isRecognizedAbsence(for: "2026-11-25", now: now))
        }
        XCTAssertFalse(observation().isRecognizedAbsence(for: "2026-11-25", now: now.addingTimeInterval(601)))
        XCTAssertTrue(observation().displayStatus(for: "2026-11-25", now: now).contains("不能判定安全"))
    }

    func testTypedFailureNeverLooksLikeFreshRanking() throws {
        let raw = Data(#"{"status":"unavailable","error_code":"rate_limited"}"#.utf8)
        let value = try JSONDecoder().decode(ProviderObservation.self, from: raw)
        XCTAssertEqual(value.errorCode, .rateLimited)
        XCTAssertFalse(value.isUsableRanking(for: "2026-11-25", now: Date()))
        XCTAssertTrue(value.displayStatus(for: "2026-11-25", now: Date()).contains("限流"))
    }
    func testStandaloneProviderDecodesAndRejectsStaleObservation() throws {
        let raw = Data(#"{"status":"listed","requested_date":"2026-11-25","retrieved_at":"2026-11-25T12:00:00Z","rank":7,"download_display":"2 GB","upload_display":"1 GB","total_display":"3 GB","units_verified":false}"#.utf8)
        let value = try JSONDecoder().decode(ProviderObservation.self, from: raw)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:00:30Z"))
        XCTAssertTrue(value.isFresh(for: "2026-11-25", now: now))
        XCTAssertFalse(value.isFresh(for: "2026-11-25", now: now.addingTimeInterval(601)))
        XCTAssertTrue(value.displayStatus(for: "2026-11-25", now: now).contains("未驗證"))
    }
}
