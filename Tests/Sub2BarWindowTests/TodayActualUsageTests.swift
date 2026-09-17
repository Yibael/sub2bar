import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class TodayActualUsageTests: XCTestCase {
    private func configure(_ f: StoreFixture, ids: [Int] = [1]) async throws {
        await f.store.prepareCredentials()
        var config = f.store.configuration
        config.subscriptionTimeZoneID = "Asia/Shanghai"
        try await f.store.save(config, key: "fake-secret")
        for id in ids {
            let account = try makeDecoder().decode(Account.self, from: Data("{\"id\":\(id),\"name\":\"Account \(id)\",\"platform\":\"openai\",\"type\":\"oauth\"}".utf8))
            try f.store.saveSubscription(AccountSubscription(monthlyPrice: 20, renewalDay: 12), for: account)
        }
    }

    private func settle(_ f: StoreFixture) async {
        await f.until { !f.store.isRefreshingSubscriptions && !f.store.isRefreshing && !f.store.isRefreshingQuota }
    }

    func testTodayActualIsDistinctFromStandardAndCycleAndUsesSameEligiblePins() async throws {
        let f = try StoreFixture(ids: [1, 2, 3]); defer { f.cleanup() }
        try await configure(f, ids: [1, 2, 4])
        await f.open(); await settle(f)
        XCTAssertEqual(f.store.eligibleSubscriptionIDs, [1, 2])
        XCTAssertEqual(f.store.totalTodayActualCost, 60)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 200)
        XCTAssertEqual(f.store.totalSubscriptionCost, 40)
        XCTAssertEqual(f.store.todayUsage[1], 12)
        XCTAssertEqual(f.store.todayActualSample(for: 1)?.day, "2026-09-15")
        let calls = f.backend.requests.count
        f.store.selectAdjacentPinned(1); f.store.movePinned(2, by: -1)
        XCTAssertEqual(f.store.totalTodayActualCost, 60)
        XCTAssertEqual(f.backend.requests.count, calls)
        f.store.setPanelVisible(false)
        f.store.setPinned(false, id: 1)
        XCTAssertNil(f.store.todayActualUsage[1])
        XCTAssertEqual(f.store.totalTodayActualCost, 30)
    }

    func testAdminSwitchClearsBothScopesAndReusesOneAdminDirectory() async throws {
        let f = try StoreFixture(interval: 120); defer { f.cleanup() }
        try await configure(f)
        await f.open(); await settle(f)
        let calls = f.backend.requests.count
        var config = f.store.configuration; config.includeAdminUsage = false
        try await f.store.save(config, key: "fake-secret")
        XCTAssertNil(f.store.totalTodayActualCost)
        XCTAssertNil(f.store.totalSubscriptionActualCost)
        XCTAssertEqual(f.backend.requests.count, calls)
        await f.tick(0); await settle(f)
        XCTAssertEqual(f.store.totalTodayActualCost, 25)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 80)
        XCTAssertEqual(f.backend.usersCount, 1, "Today and cycle share the same Admin membership snapshot")
        XCTAssertFalse(try XCTUnwrap(f.store.todayActualSample(for: 1)).includesAdmin)
        XCTAssertEqual(f.backend.batchCount, 1, "New statistics do not cause upstream quota probes")
        XCTAssertEqual(f.store.todayUsage[1], 12)
    }

    func testDailyPartialFailureDoesNotShowPartialTotalOrHideCycle() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        try await configure(f, ids: [1, 2]); f.backend.failedTodayStatsIDs = [2]
        await f.open(); await settle(f)
        XCTAssertNil(f.store.totalTodayActualCost)
        XCTAssertEqual(f.store.todayActualSample(for: 1)?.actualCost, 30)
        XCTAssertNotNil(f.store.todayActualErrors[2])
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 200)
        XCTAssertEqual(f.store.nextSubscriptionAt, f.date.addingTimeInterval(60))
        f.backend.failedTodayStatsIDs = []
        await f.tick(60); await settle(f)
        XCTAssertEqual(f.store.totalTodayActualCost, 60)
    }

    func testMidnightInvalidatesYesterdayAndRealZeroIsRetained() async throws {
        let f = try StoreFixture(interval: 120); defer { f.cleanup() }
        f.date = parseAPIDate("2026-09-15T15:59:59Z")!
        try await configure(f)
        await f.open(); await settle(f)
        XCTAssertEqual(f.store.totalTodayActualCost, 30)
        f.date = f.date.addingTimeInterval(1)
        XCTAssertNil(f.store.totalTodayActualCost)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 100)
        f.backend.todayActualCost = 0
        await f.tick(30); await settle(f)
        XCTAssertEqual(f.store.totalTodayActualCost, 0)
        XCTAssertEqual(f.store.todayActualSample(for: 1)?.day, "2026-09-16")
    }

    func testDailyResponseStartedYesterdayCannotPopulateToday() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.date = parseAPIDate("2026-09-15T15:59:59Z")!
        try await configure(f); f.backend.delayTodayStats = 0.15
        await f.open()
        await f.until { f.backend.statsCount == 2 }
        f.date = f.date.addingTimeInterval(1)
        await settle(f)
        XCTAssertNil(f.store.totalTodayActualCost)
        XCTAssertTrue(f.store.todayActualUsage.isEmpty)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 100)
    }

    func testCurrencyChangePreservesDailySampleButTimezoneAndCredentialsClearIt() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try await configure(f); await f.open(); await settle(f)
        let sample = try XCTUnwrap(f.store.todayActualSample(for: 1))
        let calls = f.backend.requests.count
        var config = f.store.configuration; config.actualCostCurrency = "¥"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertEqual(f.store.todayActualSample(for: 1)?.sampledAt, sample.sampledAt)
        XCTAssertEqual(subscriptionMoney(f.store.totalTodayActualCost, unit: config.actualCostCurrency), "¥30.00")
        XCTAssertEqual(f.backend.requests.count, calls)
        config.subscriptionTimeZoneID = "America/Los_Angeles"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertTrue(f.store.todayActualUsage.isEmpty)
        await f.tick(0); await settle(f)
        XCTAssertEqual(f.store.todayActualSample(for: 1)?.timeZoneID, "America/Los_Angeles")
        try await f.store.save(config, key: "new-secret")
        XCTAssertTrue(f.store.todayActualUsage.isEmpty)
        XCTAssertNil(f.store.totalTodayActualCost)
    }

    func testClosingCancelsDailyAndAuthFailurePausesPolling() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try await configure(f); f.backend.delayTodayStats = 0.15
        await f.open(); await f.until { f.backend.statsCount == 2 }
        f.store.setPanelVisible(false)
        let calls = f.backend.requests.count
        await f.tick(60)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(f.backend.requests.count, calls)
        XCTAssertTrue(f.store.todayActualUsage.isEmpty)
        f.backend.delayTodayStats = 0; f.backend.todayStatsError = 401
        await f.open(); await settle(f)
        XCTAssertFalse(f.store.canPoll)
        XCTAssertNil(f.store.totalTodayActualCost)
        XCTAssertNotNil(f.store.todayActualErrors[1])
    }

    func testTwoSecondActualCostPollingDoesNotSpeedUpStatusOrUpstreamQuota() async throws {
        let f = try StoreFixture(interval: 30, accountInterval: 10, statisticsInterval: 2); defer { f.cleanup() }
        try await configure(f); await f.open(); await settle(f)
        XCTAssertEqual(f.store.nextSubscriptionAt, f.date.addingTimeInterval(2))
        f.backend.todayActualCost = 40; f.backend.concurrency = 4
        await f.tick(2); await settle(f)
        XCTAssertEqual(f.store.totalTodayActualCost, 40)
        XCTAssertEqual(f.backend.statsCount, 4)
        XCTAssertEqual(f.backend.detailCount, 1)
        XCTAssertEqual(f.backend.todayCount, 1)
        XCTAssertEqual(f.backend.batchCount, 1)
        await f.tick(8); await settle(f)
        XCTAssertEqual(f.backend.detailCount, 2)
        XCTAssertEqual(f.backend.statsCount, 6)
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.store.concurrency, 4)
        await f.tick(20); await settle(f)
        XCTAssertEqual(f.backend.batchCount, 2)
    }

    func testChangingStatisticsIntervalUsesLastCompletionAndPreservesOtherLanes() async throws {
        let f = try StoreFixture(interval: 30, accountInterval: 10, statisticsInterval: 30); defer { f.cleanup() }
        try await configure(f); await f.open(); await settle(f)
        let quota = f.store.nextRefreshAt, runtime = f.store.nextRuntimeAt
        let sample = f.store.todayActualSample(for: 1)?.sampledAt
        let completion = f.date
        let calls = f.backend.requests.count
        f.date = f.date.addingTimeInterval(1)
        var config = f.store.configuration; config.statisticsRefreshInterval = 2
        try await f.store.save(config, key: "fake-secret")
        XCTAssertEqual(f.backend.requests.count, calls)
        XCTAssertEqual(f.store.nextSubscriptionAt, completion.addingTimeInterval(2))
        XCTAssertEqual(f.store.nextRefreshAt, quota)
        XCTAssertEqual(f.store.nextRuntimeAt, runtime)
        XCTAssertEqual(f.store.todayActualSample(for: 1)?.sampledAt, sample)
        f.backend.todayActualCost = 45
        await f.tick(1); await settle(f)
        XCTAssertEqual(f.store.totalTodayActualCost, 45)
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.backend.detailCount, 1)
        let statisticsDeadline = f.store.nextSubscriptionAt
        config.refreshInterval = 60; config.accountRefreshInterval = 15
        try await f.store.save(config, key: "fake-secret")
        XCTAssertEqual(f.store.nextSubscriptionAt, statisticsDeadline)
    }

    func testIntervalEditsPreserveInFlightStatisticsAndUseNewDelayOnCompletion() async throws {
        let f = try StoreFixture(interval: 30, statisticsInterval: 30); defer { f.cleanup() }
        try await configure(f); f.backend.delayTodayStats = 0.15
        await f.open(); await f.until { f.backend.statsCount == 2 }
        let calls = f.backend.requests.count
        var config = f.store.configuration
        config.statisticsRefreshInterval = 5; config.accountRefreshInterval = 10; config.refreshInterval = 60
        try await f.store.save(config, key: "fake-secret")
        XCTAssertTrue(f.store.isRefreshingSubscriptions)
        XCTAssertEqual(f.backend.requests.count, calls)
        await settle(f)
        XCTAssertEqual(f.store.totalTodayActualCost, 30)
        XCTAssertEqual(f.store.nextSubscriptionAt, f.date.addingTimeInterval(5))
        XCTAssertEqual(f.backend.statsCount, 2)
    }

    func testShorteningStatisticsIntervalKeepsFailureBackoffAndHiddenPanelDoesNotPoll() async throws {
        let f = try StoreFixture(interval: 120, statisticsInterval: 30); defer { f.cleanup() }
        try await configure(f); f.backend.todayStatsError = 503
        await f.open(); await settle(f)
        let retry = f.store.nextSubscriptionAt
        XCTAssertEqual(retry, f.date.addingTimeInterval(60))
        var config = f.store.configuration; config.statisticsRefreshInterval = 2
        try await f.store.save(config, key: "fake-secret")
        XCTAssertEqual(f.store.nextSubscriptionAt, retry)
        await f.tick(2); await settle(f)
        XCTAssertEqual(f.backend.statsCount, 2)
        f.backend.todayStatsError = 0
        await f.tick(58); await settle(f)
        XCTAssertEqual(f.store.totalTodayActualCost, 30)
        XCTAssertEqual(f.store.nextSubscriptionAt, f.date.addingTimeInterval(2))
        f.store.setPanelVisible(false)
        let calls = f.backend.requests.count
        config.statisticsRefreshInterval = 5
        try await f.store.save(config, key: "fake-secret")
        await f.tick(120)
        XCTAssertEqual(f.backend.requests.count, calls)
        XCTAssertNil(f.store.nextSubscriptionAt)
    }
}
