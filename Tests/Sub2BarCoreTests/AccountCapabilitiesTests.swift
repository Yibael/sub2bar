import XCTest
@testable import Sub2BarCore

final class AccountCapabilitiesTests: XCTestCase {
    private func account(platform: String = "openai", type: String? = "apikey", fields: [String: Any] = [:]) throws -> Account {
        var json: [String: Any] = ["id": 1, "name": "API fixture", "platform": platform, "status": "active", "schedulable": true]
        if let type { json["type"] = type }
        json.merge(fields) { _, new in new }
        return try makeDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testQueryEligibilityUsesPlatformAndTypeNotConfiguredQuota() throws {
        for platform in ["openai", "anthropic"] {
            for type in ["apikey", "api_key", "api-key", "bedrock"] {
                let value = try account(platform: platform, type: type, fields: ["quota_daily_limit": 100])
                XCTAssertFalse(value.supportsUsageQuery)
                XCTAssertTrue(value.isAPIKeyAccount)
                XCTAssertFalse(value.supportsSubscription)
                XCTAssertEqual(value.localQuotas.count, 1)
            }
            XCTAssertTrue(try account(platform: platform, type: "oauth").supportsUsageQuery)
        }
        XCTAssertTrue(try account(platform: "anthropic", type: "setup-token").supportsPassiveUsage)
        XCTAssertTrue(try account(platform: "anthropic", type: "setup-token").supportsUsageQuery)
        XCTAssertTrue(try account(platform: "gemini").supportsUsageQuery)
        XCTAssertTrue(try account(platform: "antigravity", type: "oauth").supportsUsageQuery)
        XCTAssertFalse(try account(type: nil).supportsUsageQuery)
        XCTAssertFalse(try account(platform: "unknown", type: "oauth").supportsUsageQuery)
    }

    func testEveryConfiguredDimensionAppearsIndependentlyInStableOrder() throws {
        let cases: [([String: Any], [AccountQuota.Kind])] = [
            ([:], []), (["quota_daily_limit": 0, "quota_weekly_limit": -1], []),
            (["quota_daily_limit": 100], [.daily]), (["quota_weekly_limit": 500], [.weekly]),
            (["quota_limit": 1000], [.total]),
            (["quota_daily_limit": 100, "quota_weekly_limit": 500, "quota_limit": 1000], [.daily, .weekly, .total])
        ]
        for (fields, expected) in cases {
            XCTAssertEqual(try account(fields: fields).localQuotas.map(\.kind), expected)
        }
        XCTAssertTrue(try account(type: "oauth", fields: ["quota_daily_limit": 100]).localQuotas.isEmpty)
    }

    func testConfiguredButMissingUsedStaysUnknownAndZeroStaysZero() throws {
        let quotas = try account(fields: ["quota_daily_limit": 100, "quota_weekly_limit": 100,
                                         "quota_weekly_used": 0, "quota_limit": 100, "quota_used": -1]).localQuotas
        XCTAssertNil(quotas[0].used)
        XCTAssertNil(quotas[0].percentage)
        XCTAssertEqual(quotas[1].percentage, 0)
        XCTAssertNil(quotas[2].percentage)
    }

    func testResetTimesUseFixedServerDeadlineOrRollingStartNeverNow() throws {
        let value = try account(fields: ["quota_daily_limit": 100, "quota_weekly_limit": 500, "quota_limit": 1000,
            "quota_daily_reset_mode": "fixed", "quota_daily_reset_at": "2026-09-23T04:00:00Z",
            "extra": ["quota_daily_start": "2026-09-21T01:00:00Z", "quota_weekly_start": "2026-09-20T01:00:00Z"]])
        XCTAssertEqual(value.localQuotas[0].resetDate, parseAPIDate("2026-09-23T04:00:00Z"))
        XCTAssertEqual(value.localQuotas[1].resetDate, parseAPIDate("2026-09-27T01:00:00Z"))
        XCTAssertNil(value.localQuotas[2].resetDate)
        let unknown = try account(fields: ["quota_daily_limit": 100, "quota_daily_reset_mode": "fixed",
                                          "extra": ["quota_daily_start": "2026-09-20T01:00:00Z"]])
        XCTAssertNil(unknown.localQuotas[0].resetDate, "Missing fixed deadline must not silently become rolling")
        XCTAssertNil(try account(fields: ["quota_daily_limit": 100]).localQuotas[0].resetDate)
    }

    func testDailyAndTotalWarningsAffectOverviewWithoutInventingOAuthEstimates() throws {
        for fields in [["quota_daily_limit": 100, "quota_daily_used": 95], ["quota_limit": 100, "quota_used": 95]] {
            let value = try account(fields: fields)
            let pollutedUsage = UsageInfo(sevenDay: UsageWindow(utilization: 99))
            let snapshot = AccountSnapshot(account: value, usage: pollutedUsage, usageError: "old unsupported query")
            XCTAssertNil(snapshot.weeklyPercentage)
            XCTAssertNil(snapshot.estimatedWeeklyCost)
            XCTAssertNil(snapshot.weeklyCost)
            XCTAssertEqual(PinnedAccountOverview(ids: [1], snapshots: [snapshot], failedIDs: []).attention, 1)
        }
        let value = try account()
        let snapshot = AccountSnapshot(account: value, usage: nil, usageError: "old unsupported query")
        XCTAssertEqual(PinnedAccountOverview(ids: [1], snapshots: [snapshot], failedIDs: []).attention, 0)
    }

    func testExceededLocalQuotaAffectsSchedulingButExpiredWindowDoesNot() throws {
        let date = try XCTUnwrap(parseAPIDate("2026-09-22T00:00:00Z"))
        XCTAssertEqual(try account(fields: ["quota_limit": 10, "quota_used": 12]).stateLabel(at: date), "限额已用尽")
        let expired = try account(fields: ["quota_daily_limit": 10, "quota_daily_used": 12,
            "quota_daily_reset_mode": "fixed", "quota_daily_reset_at": "2026-09-21T00:00:00Z"])
        XCTAssertEqual(expired.stateLabel(at: date), "可调度")
        XCTAssertFalse(AccountSnapshot(account: expired, usage: nil).needsQuotaAttention(at: date))
    }

    func testDailyMetricsDoNotSubstituteAmountsOrCoerceMissingFieldsToZero() throws {
        let value = try makeDecoder().decode(AccountTodayStats.self, from: Data(
            #"{"standard_cost":12,"cost":8,"user_cost":15,"requests":0,"tokens":999}"#.utf8))
        XCTAssertEqual(value.standardCost, 12); XCTAssertEqual(value.accountCost, 8)
        XCTAssertEqual(value.userCost, 15); XCTAssertEqual(value.requests, 0)
        XCTAssertEqual(value.tokens, 999)
        let bad = try makeDecoder().decode(AccountTodayStats.self, from: Data(
            #"{"standard_cost":"invalid","cost":0,"user_cost":-1,"requests":1.5}"#.utf8))
        XCTAssertNil(bad.standardCost); XCTAssertEqual(bad.accountCost, 0)
        XCTAssertNil(bad.userCost); XCTAssertNil(bad.requests)
        XCTAssertNil(bad.tokens)
    }

    func testMissingInvalidAndZeroTokenCountsDoNotMasqueradeAsEachOther() throws {
        for raw in ["null", "-1", "1.5", "\"invalid\"", "9223372036854775808"] {
            let stats = try makeDecoder().decode(AccountTodayStats.self, from: Data("{\"tokens\":\(raw)}".utf8))
            XCTAssertNil(stats.tokens)
        }
        let zero = try makeDecoder().decode(AccountTodayStats.self, from: Data(#"{"tokens":0}"#.utf8))
        XCTAssertEqual(zero.tokens, 0)
    }
}
