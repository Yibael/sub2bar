import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class MonitorTests: XCTestCase {
    func testFailedCredentialSavePreservesPreviousConnectionAndStatistics() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        await f.vault.denyWrites()
        var config = f.store.configuration; config.serverURL = "https://other.example.invalid"
        do { try await f.store.save(config, key: "new-secret"); XCTFail("Expected storage failure") }
        catch { XCTAssertEqual(error as? LocalCredentialError, .unavailable) }
        XCTAssertEqual(f.store.configuration.serverURL, "https://example.invalid")
        XCTAssertEqual(f.store.cachedKey(), "fake-secret")
        XCTAssertEqual(f.store.estimatedTotal, 50)
        XCTAssertTrue(f.store.canPoll)
        XCTAssertFalse(f.store.isSaving)
    }

    func testConfiguredAccountCadenceDoesNotChangeQuotaCadence() async throws {
        let f = try StoreFixture(interval: 5, accountInterval: 10); defer { f.cleanup() }
        await f.open()
        f.backend.concurrency = 4; f.backend.usageCost = 30
        await f.tick(5)
        XCTAssertEqual(f.backend.detailCount, 1)
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertEqual(f.store.concurrency, 1)
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 30)
        await f.tick(5)
        XCTAssertEqual(f.backend.detailCount, 2)
        XCTAssertEqual(f.backend.batchCount, 3)
        XCTAssertEqual(f.store.concurrency, 4)
    }

    func testBatchFallbackIsRememberedAndUsesNormalSingleQueries() async throws {
        for platform in ["openai", "anthropic"] {
            let f = try StoreFixture(); defer { f.cleanup() }
            f.backend.platform = platform; f.backend.batchUnavailable = true
            await f.open()
            XCTAssertEqual(f.backend.batchCount, 1)
            XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
            await f.tick(5)
            XCTAssertEqual(f.backend.batchCount, 1, "Do not retry an unsupported route every cycle")
            XCTAssertEqual(f.backend.activeCount, platform == "openai" ? 2 : 0)
            XCTAssertEqual(f.backend.passiveCount, platform == "anthropic" ? 2 : 0)
        }
    }

    func testQuotaFailureDoesNotFallbackAndDuplicateRequests() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.usageError = 503
        await f.open()
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.backend.activeCount, 0)
        XCTAssertNotNil(f.store.snapshots.first?.usageError)
        XCTAssertEqual(f.store.nextRefreshAt, f.date.addingTimeInterval(10))
    }

    func testQuotaAuthFailureStopsPolling() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.usageError = 401
        f.store.setPanelVisible(true)
        await f.until { f.store.credentialError != nil }
        XCTAssertFalse(f.store.canPoll)
        XCTAssertNil(f.store.nextRefreshAt)
        XCTAssertFalse(f.store.showsQuotaLoading)
        let count = f.backend.requests.count
        await f.tick(120)
        XCTAssertEqual(f.backend.requests.count, count)
    }

    func testUnchangedSavePreservesSnapshotsDirectoryAndDeadlines() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        f.store.loadAvailableAccounts()
        await f.until { f.store.hasLoadedAccounts }
        let requests = f.backend.requests.count
        let deadline = f.store.nextRefreshAt
        let updated = f.store.snapshots.first?.statisticsUpdatedAt
        try await f.store.save(f.store.configuration, key: "fake-secret")
        XCTAssertEqual(f.backend.requests.count, requests)
        XCTAssertEqual(f.store.nextRefreshAt, deadline)
        XCTAssertEqual(f.store.snapshots.first?.statisticsUpdatedAt, updated)
        XCTAssertEqual(f.store.estimatedTotal, 50)
        XCTAssertEqual(f.store.availableAccounts.count, 1)
        XCTAssertTrue(f.store.hasLoadedAccounts)
    }

    func testSavingIntervalsWhileHiddenPreservesCachedValuesWithoutRequesting() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        f.store.setPanelVisible(false)
        let count = f.backend.requests.count
        var config = f.store.configuration; config.refreshInterval = 120; config.accountRefreshInterval = 15
        try await f.store.save(config, key: "fake-secret")
        await f.tick(600)
        XCTAssertEqual(f.backend.requests.count, count)
        XCTAssertEqual(f.store.estimatedTotal, 50)
        XCTAssertNil(f.store.nextRefreshAt)
        await f.open()
        XCTAssertEqual(f.store.nextRefreshAt, f.date.addingTimeInterval(120))
        XCTAssertEqual(f.store.nextRuntimeAt, f.date.addingTimeInterval(15))
    }

    func testChangingServerOrKeyClearsOldDataWithoutConnecting() async throws {
        for changeServer in [true, false] {
            let f = try StoreFixture(); defer { f.cleanup() }
            await f.open()
            let count = f.backend.requests.count
            var config = f.store.configuration
            if changeServer { config.serverURL = "https://other.example.invalid" }
            try await f.store.save(config, key: changeServer ? "fake-secret" : "new-secret")
            XCTAssertTrue(f.store.snapshots.isEmpty)
            XCTAssertNil(f.store.estimatedTotal)
            XCTAssertNil(f.store.lastUpdated)
            XCTAssertFalse(f.store.canPoll)
            f.store.refresh(); await f.tick(600)
            XCTAssertEqual(f.backend.requests.count, count)
            XCTAssertEqual(f.store.pinCount, changeServer ? 0 : 1)
        }
    }

    func testCancelledOldQuotaCannotRestoreDataAfterServerChange() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.delayActive = 0.3; f.backend.usageCost = 99
        f.date = f.date.addingTimeInterval(5)
        f.store.refresh()
        await f.until { f.backend.batchCount == 2 }
        var config = f.store.configuration; config.serverURL = "https://other.example.invalid"
        try await f.store.save(config, key: "fake-secret")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(f.store.snapshots.isEmpty)
        XCTAssertNil(f.store.estimatedTotal)
        XCTAssertFalse(f.store.isRefreshingQuota)
    }

    func testQuotaDeadlineRequestsWholeUsageResponseAndShowsLoading() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        await f.until { !f.store.showsQuotaLoading }
        f.backend.usagePercentage = 87
        f.backend.delayActive = 0.4
        f.date = f.date.addingTimeInterval(5)
        f.store.runDueRefreshes()
        await f.until { f.backend.batchCount == 2 }
        XCTAssertTrue(f.store.isRefreshingQuota)
        XCTAssertTrue(f.store.showsQuotaLoading)
        XCTAssertNil(f.store.secondsUntilRefresh(at: f.date))
        XCTAssertNotEqual(f.store.snapshots.first?.weeklyPercentage, 87)
        await f.until { !f.store.isRefreshing && !f.store.isRefreshingUsage }
        XCTAssertEqual(f.store.snapshots.first?.weeklyPercentage, 87)
        XCTAssertEqual(f.backend.detailCount, 2)
        XCTAssertEqual(f.backend.batchCount, 2, "One quota batch per cycle")
        XCTAssertEqual(f.backend.activeCount, 0, "No duplicate single-account usage requests")
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 5)
    }

    func testFastQuotaLoadingRemainsVisibleWithoutDelayingPollingAndClearsOnClose() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        await f.until { !f.store.showsQuotaLoading }
        f.date = f.date.addingTimeInterval(5)
        f.store.runDueRefreshes()
        XCTAssertTrue(f.store.showsQuotaLoading)
        await f.until { !f.store.isRefreshing && !f.store.isRefreshingUsage }
        XCTAssertTrue(f.store.showsQuotaLoading, "Fast requests must still produce visible feedback")
        XCTAssertEqual(f.store.nextRefreshAt, f.date.addingTimeInterval(5))
        XCTAssertEqual(f.store.nextRuntimeAt, f.date.addingTimeInterval(2))
        f.store.setPanelVisible(false)
        XCTAssertFalse(f.store.showsQuotaLoading)
    }

    func testNewQuotaRequestCannotBeHiddenByPreviousLoadingTimer() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        XCTAssertTrue(f.store.showsQuotaLoading)
        f.backend.delayActive = 0.6
        f.date = f.date.addingTimeInterval(5)
        f.store.refresh()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(f.store.isRefreshingQuota)
        XCTAssertTrue(f.store.showsQuotaLoading)
        await f.until { !f.store.isRefreshingUsage && !f.store.showsQuotaLoading }
    }

    func testAccountFiltersAppearOnlyAboveFivePins() throws {
        for count in [0, 1, 5, 6] {
            let f = try StoreFixture(ids: Array(1..<(count + 1)))
            defer { f.cleanup() }
            XCTAssertEqual(f.store.showsAccountFilters, count > 5)
        }
    }

    func testHiddenFiltersDoNotHideAccountsAndResetWhenPinCountDrops() async throws {
        let f = try StoreFixture(ids: [1, 2, 3, 4, 5, 6]); defer { f.cleanup() }
        await f.open()
        f.store.search = "Account 6"
        XCTAssertEqual(f.store.filtered.map(\.id), [6])
        f.store.platform = "Claude"
        XCTAssertTrue(f.store.filtered.isEmpty)
        f.store.setPanelVisible(false)
        f.store.setPinned(false, id: 6)
        XCTAssertFalse(f.store.showsAccountFilters)
        XCTAssertEqual(f.store.search, "")
        XCTAssertEqual(f.store.platform, "全部")
        XCTAssertEqual(f.store.filtered.map(\.id), [1, 2, 3, 4, 5])
        // Even a stale binding must not apply filters while the controls hide.
        f.store.search = "no match"; f.store.platform = "Claude"
        XCTAssertEqual(f.store.filtered.count, 5)
    }

    func testConnectionStateDuringInitialLoadPollingAndClose() async throws {
        let f = try StoreFixture(interval: 15); defer { f.cleanup() }
        await f.store.prepareCredentials()
        XCTAssertEqual(f.store.connectionState, .disconnected)
        f.backend.delayRuntime = 0.2
        f.store.setPanelVisible(true)
        await f.until { f.backend.detailCount == 1 }
        XCTAssertEqual(f.store.connectionState, .connecting)
        await f.until { !f.store.isRefreshing && !f.store.isRefreshingUsage }
        XCTAssertEqual(f.store.connectionState, .connected)
        f.date = f.date.addingTimeInterval(2)
        f.store.runDueRefreshes()
        XCTAssertTrue(f.store.isRefreshing)
        XCTAssertEqual(f.store.connectionState, .connected)
        f.store.setPanelVisible(false)
        XCTAssertEqual(f.store.connectionState, .disconnected)
    }

    func testConnectionFailureAndRecovery() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.error = 503
        await f.open()
        XCTAssertEqual(f.store.connectionState, .failed)
        f.backend.error = 0
        await f.tick(5)
        XCTAssertEqual(f.store.connectionState, .connected)
    }

    func testRuntimePollingDoesNotShowQuotaLoading() async throws {
        let f = try StoreFixture(interval: 15); defer { f.cleanup() }
        await f.open()
        await f.until { !f.store.showsQuotaLoading }
        f.backend.delayRuntime = 0.2
        // Account status polls must not change the quota loading indicator.
        for interval in [2.0, 3.0] {
            f.date = f.date.addingTimeInterval(interval)
            f.store.runDueRefreshes()
            XCTAssertTrue(f.store.isRefreshing)
            XCTAssertFalse(f.store.isRefreshingUsage)
            XCTAssertFalse(f.store.showsQuotaLoading)
            await f.until { !f.store.isRefreshing }
            XCTAssertFalse(f.store.isRefreshingUsage)
        }
    }

    func testActiveQuotaLoadingEndsWhenRequestFinishes() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.delayActive = 0.2
        f.store.setPanelVisible(true)
        await f.until { f.backend.batchCount == 1 }
        XCTAssertTrue(f.store.isRefreshingUsage)
        await f.until { !f.store.isRefreshingQuota }
        XCTAssertFalse(f.store.isRefreshingUsage)
    }

    func testPassiveQuotaLoadingClearsOnClose() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.platform = "anthropic"
        f.backend.delayPassive = 0.2
        f.store.setPanelVisible(true)
        await f.until { f.backend.batchCount == 1 }
        XCTAssertTrue(f.store.isRefreshingUsage)
        f.store.setPanelVisible(false)
        XCTAssertFalse(f.store.isRefreshingUsage)
    }

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
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.backend.batchIDs, [[7, 2]])
        XCTAssertFalse(f.backend.requests.contains { $0.contains("/accounts?") })
        let counts = await f.vault.counts(); XCTAssertEqual(counts.reads, 1)
    }
    func testAccountResponseUpdatesConcurrencyAndStatusTogether() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        let stateTime = f.store.statusUpdatedAt
        f.backend.concurrency = 4; f.backend.status = "error"
        await f.tick(2)
        XCTAssertEqual(f.store.concurrency, 4)
        XCTAssertEqual(f.store.snapshots.first?.account.status, "error")
        XCTAssertNotEqual(f.store.statusUpdatedAt, stateTime)
        await f.tick(3)
        XCTAssertEqual(f.store.snapshots.first?.account.status, "error")
        XCTAssertEqual(f.backend.detailCount, 3)
        XCTAssertEqual(f.backend.batchCount, 2)
    }
    func testQuotaFiveSecondsUpdatesPercentageAndCostAtomically() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.percentage = 80
        f.backend.usagePercentage = 80
        f.backend.usageCost = 40
        await f.tick(2)
        XCTAssertEqual(f.store.snapshots.first?.weeklyPercentage, 50, "Account extra must not overwrite quota-response data")
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
        await f.tick(3)
        XCTAssertEqual(f.store.snapshots.first?.weeklyPercentage, 80)
        XCTAssertEqual(f.store.snapshots.first?.estimatedWeeklyCost, 50)
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 40)
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertEqual(f.backend.activeCount, 0)
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
        XCTAssertEqual(f.backend.batchCount, 2)
    }
    func testManualRefreshDoesNotDuplicateInFlightUsage() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.delayActive = 0.2
        f.date = f.date.addingTimeInterval(5)
        f.store.refresh()
        await f.until { f.backend.batchCount == 2 }
        for _ in 0..<4 {
            f.store.refresh()
        }
        await f.until { !f.store.isRefreshing && !f.store.isRefreshingQuota }
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertEqual(f.backend.activeCount, 0)
        let counts = await f.vault.counts(); XCTAssertEqual(counts.reads, 1)
    }
    func testCancelledQuotaResultCannotReplaceNewResponseOnReopen() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.delayActive = 0.3
        f.store.setPanelVisible(true)
        await f.until { f.backend.batchCount == 1 }
        f.store.setPanelVisible(false)
        XCTAssertFalse(f.store.isRefreshingQuota)
        f.backend.delayActive = 0; f.backend.usageCost = 45
        await f.open()
        XCTAssertEqual(f.backend.batchCount, 1, "Reopening cannot bypass the cancelled request's cooldown")
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(f.store.snapshots.first?.weeklyCost)
        await f.tick(5)
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 45)
    }
    func testSlowUpstreamDoesNotBlockTwoSecondRuntime() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.delayActive = 0.2
        f.store.setPanelVisible(true)
        await f.until { f.backend.batchCount == 1 && !f.store.isRefreshing }
        f.backend.concurrency = 5
        f.date = f.date.addingTimeInterval(2)
        f.store.runDueRefreshes()
        await f.until { f.store.concurrency == 5 }
        XCTAssertTrue(f.store.isRefreshingQuota)
        XCTAssertEqual(f.backend.detailCount, 2)
        await f.until { !f.store.isRefreshingQuota }
    }
    func testClaudeUsesSameNormalBatchCadenceWithoutExtraSingleUsageRequests() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.platform = "anthropic"
        await f.open()
        XCTAssertEqual(f.backend.activeCount, 0)
        XCTAssertEqual(f.backend.batchCount, 1)
        await f.tick(5)
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertEqual(f.backend.activeCount, 0)
    }
    func testSavingIntervalsRetainsStatisticsAndOnlyReschedules() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        let count = f.backend.requests.count
        var config = f.store.configuration; config.refreshInterval = 30
        try await f.store.save(config, key: "fake-secret")
        XCTAssertEqual(f.backend.requests.count, count)
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
        XCTAssertEqual(f.store.estimatedTotal, 50)
        XCTAssertEqual(f.store.nextRefreshAt, f.date.addingTimeInterval(30))
        XCTAssertTrue(f.store.canPoll)
        await f.tick(2)
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.store.estimatedTotal, 50)
        await f.tick(28)
        XCTAssertEqual(f.backend.batchCount, 2)
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
        XCTAssertEqual(f.backend.batchCount, 0)
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
        XCTAssertEqual(f.store.connectionState, .notConfigured)
        XCTAssertNotNil(f.store.credentialError)
    }
    func testAuthenticationFailurePausesAllLanesWithoutReloadLoop() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.error = 401
        f.store.setPanelVisible(true)
        await f.until { f.store.credentialError != nil }
        XCTAssertEqual(f.store.connectionState, .failed)
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
        await f.open()
        f.backend.usageError = 503
        await f.tick(5)
        XCTAssertEqual(f.store.snapshots.first?.weeklyPercentage, 50)
        XCTAssertEqual(f.store.estimatedTotal, 50)
        XCTAssertNotNil(f.store.snapshots.first?.usageError)
        XCTAssertEqual(f.store.connectionState, .connected)
        XCTAssertEqual(f.store.nextRefreshAt, f.date.addingTimeInterval(10))
        await f.tick(5)
        XCTAssertEqual(f.backend.batchCount, 2)
        await f.tick(5)
        XCTAssertEqual(f.backend.batchCount, 3)
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
        XCTAssertEqual(f.backend.batchCount, 1)
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
