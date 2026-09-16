import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class MonitorTests: XCTestCase {
    func testStartupAndHiddenOperationsNeverRequestNetwork() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.store.prepareCredentials()
        f.store.start(); f.store.refresh(); f.store.resumeAfterSleep(); f.store.setPinned(true, id: 2)
        await f.tick(1200)
        XCTAssertTrue(f.backend.requests.isEmpty)
        XCTAssertNil(f.store.nextRefreshAt)
        let counts = await f.vault.counts(); XCTAssertEqual(counts.reads, 1)
    }
    func testOpenLoadsLocalKeyOnceAndOnlyPinnedAccounts() async throws {
        let f = try StoreFixture(ids: [7, 2]); defer { f.cleanup() }
        await f.open()
        XCTAssertEqual(f.store.snapshots.map(\.id), [7, 2])
        XCTAssertEqual(f.backend.detailCount, 2)
        XCTAssertEqual(f.backend.activeCount, 2)
        XCTAssertFalse(f.backend.requests.contains { $0.contains("/accounts?") })
        let counts = await f.vault.counts(); XCTAssertEqual(counts.reads, 1)
    }
    func testRuntimeTwoSecondsStatusFiveSecondsAndCoalescing() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        let stateTime = f.store.statusUpdatedAt
        f.backend.concurrency = 4; f.backend.status = "error"
        await f.tick(2)
        XCTAssertEqual(f.store.concurrency, 4)
        XCTAssertEqual(f.store.snapshots.first?.account.status, "active")
        XCTAssertEqual(f.store.statusUpdatedAt, stateTime)
        await f.tick(3)
        XCTAssertEqual(f.store.snapshots.first?.account.status, "error")
        XCTAssertEqual(f.backend.detailCount, 3)
        XCTAssertEqual(f.backend.activeCount, 1)
    }
    func testQuotaFiveSecondsUsesAccountCacheNotActiveEndpoint() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.percentage = 80
        await f.tick(2)
        await f.tick(3)
        XCTAssertEqual(f.store.snapshots.first?.weeklyPercentage, 80)
        XCTAssertEqual(f.store.snapshots.first?.estimatedWeeklyCost, 50)
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
        XCTAssertEqual(f.backend.activeCount, 1)
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 5)
    }
    func testQuotaIntervalDoesNotSlowRuntimeAndCountsDown() async throws {
        let f = try StoreFixture(interval: 15); defer { f.cleanup() }
        await f.open()
        let initial = f.store.quotaUpdatedAt
        f.backend.concurrency = 3
        await f.tick(2)
        XCTAssertEqual(f.store.concurrency, 3)
        XCTAssertEqual(f.store.quotaUpdatedAt, initial)
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 13)
        await f.tick(13)
        XCTAssertEqual(f.store.quotaUpdatedAt, f.date)
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 15)
        XCTAssertEqual(f.backend.activeCount, 1)
    }
    func testHighCostBudgetSurvivesReopenManualRefreshAndRepin() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        for _ in 0..<4 {
            f.store.setPanelVisible(false); await f.open()
            f.store.refresh()
            await f.until { !f.store.isRefreshing && !f.store.isRefreshingQuota }
        }
        f.store.setPinned(false, id: 1); f.store.setPinned(true, id: 1)
        await f.until { !f.store.isRefreshing && !f.store.isRefreshingQuota }
        await f.tick(599)
        XCTAssertEqual(f.backend.activeCount, 1)
        await f.tick(2)
        XCTAssertEqual(f.backend.activeCount, 2)
        let counts = await f.vault.counts(); XCTAssertEqual(counts.reads, 1)
    }
    func testCancelledHighCostRequestDoesNotRetryOnReopen() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.delayActive = 0.3
        f.store.setPanelVisible(true)
        await f.until { f.backend.activeCount == 1 }
        f.store.setPanelVisible(false)
        XCTAssertFalse(f.store.isRefreshingUpstream)
        await f.open()
        XCTAssertEqual(f.backend.activeCount, 1)
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(f.store.snapshots.first?.statisticsUsage)
    }
    func testSlowUpstreamDoesNotBlockTwoSecondRuntime() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.delayActive = 0.2
        f.store.setPanelVisible(true)
        await f.until { f.backend.activeCount == 1 && !f.store.isRefreshing }
        f.backend.concurrency = 5
        f.date = f.date.addingTimeInterval(2)
        f.store.runDueRefreshes()
        await f.until { f.store.concurrency == 5 }
        XCTAssertTrue(f.store.isRefreshingUpstream)
        XCTAssertEqual(f.backend.detailCount, 2)
        await f.until { !f.store.isRefreshingUpstream }
    }
    func testPassiveClaudeCanRefreshFastWithoutActiveUsage() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.platform = "anthropic"
        await f.open()
        XCTAssertEqual(f.backend.activeCount, 0)
        XCTAssertEqual(f.backend.passiveCount, 1)
        await f.tick(5)
        XCTAssertEqual(f.backend.passiveCount, 2)
        XCTAssertEqual(f.backend.activeCount, 0)
    }
    func testSaveOnlyPersistsWithoutConnectingEvenIfPanelVisible() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        let count = f.backend.requests.count
        var config = f.store.configuration; config.refreshInterval = 30
        try await f.store.save(config, key: "fake-secret")
        f.store.refresh(); await f.tick(1000)
        XCTAssertEqual(f.backend.requests.count, count)
        let counts = await f.vault.counts(); XCTAssertEqual(counts.writes, 0)
        f.store.setPanelVisible(false); await f.open()
        XCTAssertGreaterThan(f.backend.detailCount, 1)
    }
    func testDirectoryIsExplicitAndNeverTriggersUsage() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.store.loadAvailableAccounts()
        await f.until { f.store.hasLoadedAccounts }
        XCTAssertEqual(f.backend.requests.count, 1)
        XCTAssertEqual(f.backend.activeCount, 0)
        XCTAssertFalse(f.store.isPanelVisible)
    }
    func testMissingLocalKeyDoesNotRequestOrRepeatedlyReadDisk() async throws {
        let f = try StoreFixture(vault: MemoryVault(values: [:])); defer { f.cleanup() }
        await f.store.prepareCredentials()
        for _ in 0..<4 {
            f.store.setPanelVisible(true); await f.store.prepareCredentials()
            f.store.refresh(); f.store.setPanelVisible(false)
        }
        XCTAssertTrue(f.backend.requests.isEmpty)
        let counts = await f.vault.counts(); XCTAssertEqual(counts.reads, 1)
        XCTAssertTrue(f.store.needsCredentialAccess)
        XCTAssertNotNil(f.store.credentialError)
    }
    func testAuthenticationFailurePausesAllLanesWithoutReloadLoop() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.error = 401
        f.store.setPanelVisible(true)
        await f.until { f.store.credentialError != nil }
        let count = f.backend.requests.count
        f.store.setPanelVisible(false); f.store.setPanelVisible(true)
        await f.store.prepareCredentials(); await f.tick(1000)
        XCTAssertEqual(f.backend.requests.count, count)
        XCTAssertNil(f.store.nextRuntimeAt)
        XCTAssertNil(f.store.nextRefreshAt)
        let counts = await f.vault.counts(); XCTAssertEqual(counts.reads, 1)
        XCTAssertFalse(f.store.credentialError?.contains("private-secret") == true)
    }
    func testUpstreamFailureRetainsCacheAndDoesNotRetryRapidly() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.usageError = 503
        await f.open()
        XCTAssertEqual(f.store.snapshots.first?.weeklyPercentage, 40)
        XCTAssertNotNil(f.store.snapshots.first?.usageError)
        await f.tick(5); await f.tick(5)
        XCTAssertEqual(f.backend.activeCount, 1)
        XCTAssertGreaterThan(f.backend.detailCount, 1)
    }
    func testRuntimeFailureBacksOffAndNeverPresentsZeroConcurrency() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.error = 429
        await f.tick(2)
        XCTAssertNil(f.store.concurrency)
        XCTAssertEqual(f.store.nextRuntimeAt, f.date.addingTimeInterval(4))
        let count = f.backend.detailCount
        await f.tick(1)
        XCTAssertEqual(f.backend.detailCount, count)
    }
    func testClosedAndSleepingPanelStopsEveryLane() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        f.store.suspendForSleep()
        let count = f.backend.requests.count
        await f.tick(2000)
        XCTAssertEqual(f.backend.requests.count, count)
        f.store.setPanelVisible(false); f.store.resumeAfterSleep()
        await f.tick(2000)
        XCTAssertEqual(f.backend.requests.count, count)
        XCTAssertNil(f.store.nextRuntimeAt)
        XCTAssertNil(f.store.nextStatusAt)
        XCTAssertNil(f.store.nextRefreshAt)
    }
    func testNoPinsMeansNoRequestsAndPinOrderPersists() async throws {
        let f = try StoreFixture(ids: []); defer { f.cleanup() }
        f.store.setPanelVisible(true); await f.store.prepareCredentials(); f.store.refresh()
        XCTAssertTrue(f.backend.requests.isEmpty)
        f.store.setPanelVisible(false)
        f.store.setPinned(true, id: 8); f.store.setPinned(true, id: 3); f.store.setPinned(true, id: 8)
        XCTAssertEqual(f.store.pinnedIDs, [8, 3])
        let restored = AppStore(defaults: f.defaults, credentials: CredentialSession(storage: f.vault), automaticallySchedule: false)
        XCTAssertEqual(restored.pinnedIDs, [8, 3])
        XCTAssertTrue(f.backend.requests.isEmpty)
    }
    func testLateRuntimeResultAfterClosingCannotOverwriteReopenedPanel() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.delayRuntime = 0.25
        f.store.setPanelVisible(true)
        await f.until { f.backend.detailCount == 1 }
        f.store.setPanelVisible(false)
        f.backend.delayRuntime = 0; f.backend.concurrency = 4
        await f.open()
        await f.until { f.store.concurrency == 4 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(f.store.concurrency, 4)
        XCTAssertEqual(f.backend.activeCount, 1)
    }
    func testRealTimerRefreshesAndStopsOnClose() async throws {
        let f = try StoreFixture(automatic: true); defer { f.cleanup() }
        // The scheduler's injected clock must advance with real time in this test.
        await f.open()
        f.date = f.date.addingTimeInterval(2)
        await f.until { f.backend.detailCount >= 2 }
        f.store.setPanelVisible(false)
        let count = f.backend.requests.count
        f.date = f.date.addingTimeInterval(1000)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(f.backend.requests.count, count)
        XCTAssertFalse(f.store.isPolling)
    }
}
