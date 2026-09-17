import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class TodayUsageTests: XCTestCase {
    func testTodayUsageFollowsAccountCadenceNotQuotaCadence() async throws {
        let f = try StoreFixture(ids: [7, 2], interval: 30, accountInterval: 2)
        defer { f.cleanup() }
        await f.open()
        XCTAssertEqual(f.store.todayUsage, [7: 12, 2: 12])
        XCTAssertEqual(f.backend.todayBatchIDs, [[7, 2]])
        f.backend.todayCost = 18
        await f.tick(1)
        XCTAssertEqual(f.backend.todayCount, 1)
        await f.tick(1)
        XCTAssertEqual(f.store.todayUsage, [7: 18, 2: 18])
        XCTAssertEqual(f.backend.todayBatchIDs, [[7, 2], [7, 2]])
        XCTAssertEqual(f.backend.batchCount, 1, "Daily statistics must not trigger quota probes")
        XCTAssertEqual(f.backend.activeCount, 0)
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
        XCTAssertFalse(f.store.isRefreshingQuota)
    }

    func testQuotaRefreshDoesNotOverwriteOrRefreshTodayUsage() async throws {
        let f = try StoreFixture(interval: 5, accountInterval: 10)
        defer { f.cleanup() }
        await f.open()
        f.backend.todayCost = 19
        await f.tick(5)
        XCTAssertEqual(f.store.todayUsage[1], 12)
        XCTAssertEqual(f.backend.todayCount, 1)
        XCTAssertEqual(f.backend.batchCount, 2)
        await f.tick(5)
        XCTAssertEqual(f.store.todayUsage[1], 19)
        XCTAssertEqual(f.backend.todayCount, 2)
    }

    func testDailyFailuresDoNotBreakAccountStateOrShowStaleAmounts() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        await f.open()
        f.backend.todayError = 503; f.backend.concurrency = 4
        await f.tick(2)
        XCTAssertTrue(f.store.todayUsage.isEmpty)
        XCTAssertEqual(f.store.todayUsageErrors[1], "今日用量读取失败")
        XCTAssertEqual(f.store.concurrency, 4)
        XCTAssertNil(f.store.errorMessage)
        XCTAssertEqual(f.store.nextRuntimeAt, f.date.addingTimeInterval(2))
        XCTAssertEqual(f.backend.batchCount, 1)
        f.backend.todayError = 0; f.backend.todayCost = 0
        await f.tick(2)
        XCTAssertEqual(f.store.todayUsage[1], 0, "A new day may legitimately reset usage to zero")
        XCTAssertTrue(f.store.todayUsageErrors.isEmpty)
    }

    func testMissingDailyEntryIsUnavailableNotZero() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        f.backend.missingTodayIDs = [2]
        await f.open()
        XCTAssertEqual(f.store.todayUsage, [1: 12])
        XCTAssertEqual(f.store.todayUsageErrors, [2: "今日用量暂不可用"])
    }

    func testDailyAuthenticationFailureStopsPolling() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.todayError = 401
        f.store.setPanelVisible(true)
        await f.until { f.store.credentialError != nil }
        XCTAssertFalse(f.store.canPoll)
        let count = f.backend.requests.count
        await f.tick(120)
        XCTAssertEqual(f.backend.requests.count, count)
        XCTAssertTrue(f.store.todayUsage.isEmpty)
    }

    func testSlowDailyStatsDoNotBlockAccountUpdateOrInitialQuota() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.delayToday = 0.3
        f.store.setPanelVisible(true)
        await f.until { f.backend.batchCount == 1 && f.store.concurrency == 1 }
        XCTAssertTrue(f.store.todayUsage.isEmpty)
        await f.until { !f.store.isRefreshing && !f.store.isRefreshingQuota }
        XCTAssertEqual(f.store.todayUsage[1], 12)
    }

    func testClosingCancelsDailyStatsAndLateResultsCannotOverwriteReopen() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.delayToday = 0.3; f.backend.todayCost = 99
        f.date = f.date.addingTimeInterval(2)
        f.store.runDueRefreshes()
        await f.until { f.backend.todayCount == 2 }
        f.store.setPanelVisible(false)
        f.backend.delayToday = 0; f.backend.todayCost = 20
        await f.open()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(f.store.todayUsage[1], 20)
        f.store.setPanelVisible(false)
        let count = f.backend.todayCount
        await f.tick(60)
        XCTAssertEqual(f.backend.todayCount, count)
    }

    func testPinAndConnectionChangesClearDailyData() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        await f.open()
        f.store.setPanelVisible(false)
        f.store.setPinned(false, id: 2)
        XCTAssertEqual(f.store.todayUsage, [1: 12])
        var config = f.store.configuration; config.accountRefreshInterval = 10
        try await f.store.save(config, key: "fake-secret")
        XCTAssertEqual(f.store.todayUsage, [1: 12])
        config.serverURL = "https://other.example.invalid"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertTrue(f.store.todayUsage.isEmpty)
        XCTAssertTrue(f.store.todayUsageErrors.isEmpty)
    }
}
