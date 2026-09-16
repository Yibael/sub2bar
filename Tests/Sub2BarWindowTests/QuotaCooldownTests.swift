import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class QuotaCooldownTests: XCTestCase {
    func testReopenedPanelAutomaticallyWakesAtRetainedDeadline() async throws {
        let f = try StoreFixture(automatic: true); defer { f.cleanup() }
        await f.open()
        f.store.setPanelVisible(false)
        XCTAssertFalse(f.store.isPolling)
        f.date = f.date.addingTimeInterval(4.8)
        await f.open()
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 1)
        // Advance the injected clock, but let the real scheduler dispatch.
        f.date = f.date.addingTimeInterval(0.2)
        await f.until { f.backend.batchCount == 2 && !f.store.isRefreshingQuota }
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 5)
        f.store.setPanelVisible(false)
        f.date = f.date.addingTimeInterval(100)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertFalse(f.store.isPolling)
    }

    func testLegacyIndividualUsageAlsoHonorsCooldownAcrossReopen() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.batchUnavailable = true
        await f.open()
        f.store.setPanelVisible(false)
        await f.tick(2)
        await f.open()
        XCTAssertEqual(f.backend.activeCount, 1)
        XCTAssertEqual(f.backend.batchCount, 1)
        await f.tick(3)
        XCTAssertEqual(f.backend.activeCount, 2)
        XCTAssertEqual(f.backend.batchCount, 1)
    }

    func testReopenAndManualRefreshPreserveRemainingInterval() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        await f.open()
        let deadline = f.store.nextRefreshAt
        for _ in 0..<3 {
            f.store.setPanelVisible(false)
            await f.tick(2)
            await f.open()
            f.store.refresh()
            await f.until { !f.store.isRefreshing }
            XCTAssertEqual(f.backend.batchCount, 1)
            XCTAssertEqual(f.store.nextRefreshAt, deadline)
            XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
        }
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 24)
        await f.tick(23)
        XCTAssertEqual(f.backend.batchCount, 1)
        await f.tick(1)
        XCTAssertEqual(f.backend.batchCount, 2)
    }

    func testExpiredWhileHiddenQueriesOnceOnOpenWithoutCatchUp() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        await f.open()
        f.store.setPanelVisible(false)
        let requests = f.backend.requests.count
        await f.tick(400)
        XCTAssertEqual(f.backend.requests.count, requests)
        XCTAssertFalse(f.store.isPolling)
        await f.open()
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 30)
    }

    func testIntervalStartsAtResponseNotRequestStart() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        let started = f.date
        f.backend.delayActive = 0.2
        f.store.setPanelVisible(true)
        await f.until { f.backend.batchCount == 1 }
        f.date = started.addingTimeInterval(20)
        f.store.runDueRefreshes()
        XCTAssertEqual(f.backend.batchCount, 1)
        await f.until { !f.store.isRefreshingQuota }
        XCTAssertEqual(f.store.nextRefreshAt, started.addingTimeInterval(50))
        await f.tick(10)
        XCTAssertEqual(f.backend.batchCount, 1, "Thirty seconds since start is not thirty since completion")
        f.backend.delayActive = 0
        await f.tick(20)
        XCTAssertEqual(f.backend.batchCount, 2)
    }

    func testCancellationCompletesBeforeCooldownStartsAndReopenDoesNotOverlap() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        let started = f.date
        f.backend.delayActive = 1
        f.store.setPanelVisible(true)
        await f.until { f.backend.batchCount == 1 }
        f.date = started.addingTimeInterval(1)
        f.store.setPanelVisible(false)
        // No actor yield: cancellation completion can only run at t=4 or later.
        f.date = started.addingTimeInterval(4)
        f.backend.delayActive = 0
        await f.open()
        await f.until { f.store.nextRefreshAt == started.addingTimeInterval(34) }
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertNil(f.store.snapshots.first?.weeklyCost)
        await f.tick(29)
        XCTAssertEqual(f.backend.batchCount, 1)
        await f.tick(1)
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
    }

    func testChangingIntervalUsesLastCompletionInsteadOfSaveTime() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        await f.open()
        let completed = f.date
        await f.tick(8)
        var config = f.store.configuration; config.refreshInterval = 15
        try await f.store.save(config, key: "fake-secret")
        XCTAssertEqual(f.store.nextRefreshAt, completed.addingTimeInterval(15))
        XCTAssertEqual(f.backend.batchCount, 1)
        await f.tick(7)
        XCTAssertEqual(f.backend.batchCount, 2)
    }

    func testShortenedAlreadyExpiredIntervalDoesNotRequestInsideSave() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        await f.open()
        await f.tick(10)
        var config = f.store.configuration; config.refreshInterval = 5
        try await f.store.save(config, key: "fake-secret")
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 0)
        await f.tick(0)
        XCTAssertEqual(f.backend.batchCount, 2)
    }

    func testSavingDuringRequestRetainsCancellationCooldown() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        f.backend.delayActive = 1
        f.store.setPanelVisible(true)
        await f.until { f.backend.batchCount == 1 }
        f.date = f.date.addingTimeInterval(3)
        var config = f.store.configuration; config.refreshInterval = 15
        try await f.store.save(config, key: "fake-secret")
        await f.until { f.store.nextRefreshAt == f.date.addingTimeInterval(15) }
        f.store.refresh()
        await f.until { !f.store.isRefreshing }
        XCTAssertEqual(f.backend.batchCount, 1)
    }

    func testOnlyNewOrDuePinsAreIncludedAndRepinCannotBypassInterval() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        await f.open()
        f.store.setPanelVisible(false)
        await f.tick(5)
        f.store.setPinned(false, id: 1)
        f.store.setPinned(true, id: 1)
        f.store.setPinned(true, id: 2)
        await f.open()
        XCTAssertEqual(f.backend.batchIDs, [[1], [2]])
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 25)
        await f.tick(25)
        XCTAssertEqual(f.backend.batchIDs, [[1], [2], [1]])
        await f.tick(5)
        XCTAssertEqual(f.backend.batchIDs, [[1], [2], [1], [2]])
    }

    func testFailureBackoffSurvivesReopenAndShorterSetting() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        f.backend.usageError = 503
        await f.open()
        let deadline = f.date.addingTimeInterval(60)
        f.store.setPanelVisible(false)
        await f.tick(5)
        var config = f.store.configuration; config.refreshInterval = 5
        try await f.store.save(config, key: "fake-secret")
        await f.open()
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.store.nextRefreshAt, deadline)
        f.backend.usageError = 0
        await f.tick(55)
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 5)
    }

    func testPartialFailureBackoffDoesNotDelayHealthyAccounts() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        f.backend.failedUsageIDs = [2]
        await f.open()
        await f.tick(5)
        XCTAssertEqual(f.backend.batchIDs, [[1, 2], [1]])
        await f.tick(5)
        XCTAssertEqual(f.backend.batchIDs, [[1, 2], [1], [1, 2]])
        f.store.setPanelVisible(false)
        await f.tick(5)
        await f.open()
        XCTAssertEqual(f.backend.batchIDs.last, [1])
    }

    func testServerSwitchKeepsSeparateCooldownWithoutRestoringOldPayload() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        await f.open()
        let original = f.store.configuration
        f.store.setPanelVisible(false)
        var other = original; other.serverURL = "https://other.example.invalid"
        try await f.store.save(other, key: "fake-secret")
        f.store.setPinned(true, id: 1)
        await f.open()
        XCTAssertEqual(f.backend.batchCount, 2, "A different server has independent eligibility")
        f.store.setPanelVisible(false)
        await f.tick(2)
        try await f.store.save(original, key: "fake-secret")
        await f.open()
        XCTAssertEqual(f.backend.batchCount, 2)
        XCTAssertNil(f.store.snapshots.first?.weeklyCost, "Timing must not carry credential-scoped payloads")
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 28)
    }

    func testSleepWakePreservesQuotaDeadline() async throws {
        let f = try StoreFixture(interval: 30); defer { f.cleanup() }
        await f.open()
        f.store.suspendForSleep()
        await f.tick(5)
        f.store.resumeAfterSleep()
        await f.until { !f.store.isRefreshing }
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.store.secondsUntilRefresh(at: f.date), 25)
    }
}
