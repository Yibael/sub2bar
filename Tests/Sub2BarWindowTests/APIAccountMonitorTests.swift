import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class APIAccountMonitorTests: XCTestCase {
    func testAPIOnlyPinsUseDetailsAndDailyStatisticsWithoutQuotaRequestsOrLoadingLoop() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        f.backend.accountOverrides = [1: ["type": "apikey", "quota_daily_limit": 100, "quota_daily_used": 25], 2: ["type": "apikey"]]
        await f.open()
        XCTAssertEqual(f.backend.batchCount, 0)
        XCTAssertEqual(f.backend.activeCount, 0)
        XCTAssertEqual(f.backend.passiveCount, 0)
        XCTAssertNil(f.store.nextRefreshAt)
        XCTAssertTrue(f.store.quotaRefreshLabel(at: f.date).hasPrefix("状态刷新"))
        XCTAssertEqual(f.store.todayStats[1]?.accountCost, 98)
        XCTAssertEqual(f.store.todayStats[1]?.userCost, 76)
        XCTAssertEqual(f.store.todayStats[1]?.requests, 286)
        XCTAssertEqual(f.store.todayStats[1]?.tokens, 1234567)
        XCTAssertEqual(f.store.todayUsage[1], 12)
        XCTAssertEqual(f.store.partialErrors, 0)
        XCTAssertNil(f.store.estimatedTotal)
        let previous = f.backend.todayCount
        f.store.refreshManually()
        await f.until { f.backend.todayCount > previous && !f.store.isRefreshing }
        XCTAssertNil(f.store.nextRefreshAt)
        XCTAssertEqual(f.backend.batchCount, 0)
        f.backend.accountOverrides[1] = ["type": "apikey", "quota_daily_limit": 100, "quota_daily_used": 40]
        await f.tick(2)
        XCTAssertEqual(f.store.snapshots.first { $0.id == 1 }?.account.localQuotas.first?.percentage, 40)
        XCTAssertEqual(f.backend.batchCount, 0)
    }

    func testMixedPinsBatchAndLegacyFallbackOnlyQuerySupportedAccounts() async throws {
        for legacy in [false, true] {
            let f = try StoreFixture(ids: [1, 2, 3, 4]); defer { f.cleanup() }
            f.backend.batchUnavailable = legacy
            f.backend.accountOverrides = [1: ["type": "apikey", "quota_limit": 100],
                2: ["type": "oauth"], 3: ["platform": "anthropic", "type": "setup-token"],
                4: ["platform": "gemini", "type": "apikey"]]
            await f.open()
            XCTAssertEqual(f.backend.batchIDs, [[2, 3, 4]])
            XCTAssertEqual(f.backend.todayBatchIDs, [[1, 2, 3, 4]])
            XCTAssertEqual(f.backend.activeCount, legacy ? 2 : 0)
            XCTAssertEqual(f.backend.passiveCount, legacy ? 1 : 0)
            XCTAssertFalse(f.backend.requests.contains { $0.contains("/1/usage") })
            XCTAssertNil(f.store.snapshots.first { $0.id == 1 }?.usageError)
        }
    }

    func testDetailFailureRetainsKnownLimitsAndTimestampUntilRecovery() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        f.backend.accountOverrides = [1: ["type": "apikey", "quota_weekly_limit": 100, "quota_weekly_used": 60], 2: ["type": "apikey"]]
        await f.open()
        let sampledAt = f.store.accountUpdatedAt[1]
        f.backend.failedAccountIDs = [1]
        await f.tick(2)
        XCTAssertNotNil(f.store.pinnedAccountErrors[1])
        XCTAssertEqual(f.store.snapshots.first { $0.id == 1 }?.account.localQuotas.first?.percentage, 60)
        XCTAssertEqual(f.store.accountUpdatedAt[1], sampledAt)
        XCTAssertEqual(f.store.accountOverview.failed, 1)
        XCTAssertEqual(f.store.accountOverview.available, 1)
        XCTAssertEqual(f.store.quotaRefreshLabel(at: f.date), "等待重试")
        f.backend.failedAccountIDs = []
        f.backend.accountOverrides[1] = ["type": "apikey"]
        await f.tick(4)
        XCTAssertNil(f.store.pinnedAccountErrors[1])
        XCTAssertTrue(try XCTUnwrap(f.store.snapshots.first { $0.id == 1 }).account.localQuotas.isEmpty)
        XCTAssertEqual(f.store.accountUpdatedAt[1], f.date)
    }

    func testTypeChangeClearsOldOAuthUsageAndStopsQuotaScheduling() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        XCTAssertNotNil(f.store.estimatedTotal)
        f.backend.accountOverrides = [1: ["type": "apikey", "quota_limit": 100]]
        await f.tick(2)
        XCTAssertNil(f.store.snapshots.first?.usage)
        XCTAssertNil(f.store.snapshots.first?.statisticsUsage)
        XCTAssertNil(f.store.snapshots.first?.usageError)
        XCTAssertNil(f.store.nextRefreshAt)
        XCTAssertNil(f.store.estimatedTotal)
        let count = f.backend.batchCount
        await f.tick(60)
        XCTAssertEqual(f.backend.batchCount, count)
    }

    func testAPIDailyFailureClearsEveryMetricAndConnectionAndPinChangesIsolateSamples() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        f.backend.accountOverrides = [1: ["type": "apikey"], 2: ["type": "apikey"]]
        await f.open()
        f.backend.todayError = 503
        await f.tick(2)
        XCTAssertTrue(f.store.todayStats.isEmpty)
        XCTAssertNotNil(f.store.todayUsageErrors[1])
        XCTAssertEqual(f.store.concurrency, 2)
        f.backend.todayError = 0
        await f.tick(2)
        f.store.setPanelVisible(false)
        f.store.setPinned(false, id: 2)
        XCTAssertNil(f.store.todayStats[2]); XCTAssertNil(f.store.accountUpdatedAt[2])
        XCTAssertNotNil(f.store.todayStats[1])
        var config = f.store.configuration; config.serverURL = "https://other.example.invalid"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertTrue(f.store.todayStats.isEmpty)
        XCTAssertTrue(f.store.accountUpdatedAt.isEmpty)
    }
}
