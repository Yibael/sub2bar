import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class SubscriptionMonitorTests: XCTestCase {
    private func account(_ id: Int = 1, type: String = "oauth") throws -> Account {
        try makeDecoder().decode(Account.self, from: Data("{\"id\":\(id),\"name\":\"Account \(id)\",\"platform\":\"openai\",\"type\":\"\(type)\"}".utf8))
    }
    private func configure(_ f: StoreFixture, id: Int = 1, price: Decimal? = 200, day: Int? = 12) throws {
        try f.store.saveSubscription(AccountSubscription(monthlyPrice: price, renewalDay: day), for: account(id))
    }
    private func settled(_ f: StoreFixture) async {
        await f.until { !f.store.isRefreshingSubscriptions && !f.store.isRefreshing && !f.store.isRefreshingQuota }
    }

    func testCurrencyOnlySavePreservesAmountsSamplesAndEveryDeadline() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try configure(f)
        await f.open(); await settled(f)
        let requests = f.backend.requests.count
        let sample = f.store.subscriptionSample(for: 1)
        let quotaDeadline = f.store.nextRefreshAt
        let runtimeDeadline = f.store.nextRuntimeAt
        let subscriptionDeadline = f.store.nextSubscriptionAt
        var config = f.store.configuration
        config.actualCostCurrency = " ¥ "; config.subscriptionCostCurrency = "HK$"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertEqual(f.store.configuration.actualCostCurrency, "¥")
        XCTAssertEqual(f.store.configuration.subscriptionCostCurrency, "HK$")
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 100)
        XCTAssertEqual(f.store.totalSubscriptionCost, 200)
        XCTAssertEqual(f.store.subscriptions[1]?.monthlyPrice, 200)
        XCTAssertEqual(f.store.subscriptionSample(for: 1)?.sampledAt, sample?.sampledAt)
        XCTAssertEqual(f.store.nextRefreshAt, quotaDeadline)
        XCTAssertEqual(f.store.nextRuntimeAt, runtimeDeadline)
        XCTAssertEqual(f.store.nextSubscriptionAt, subscriptionDeadline)
        XCTAssertEqual(f.store.todayUsage[1], 12)
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
        XCTAssertEqual(money(f.store.todayUsage[1]), "$12.00")
        XCTAssertEqual(money(f.store.snapshots.first?.weeklyCost), "$25.00")
        XCTAssertEqual(f.backend.requests.count, requests)
        let restored = AppStore(defaults: f.defaults, credentials: CredentialSession(storage: f.vault), automaticallySchedule: false)
        XCTAssertEqual(restored.configuration.actualCostCurrency, "¥")
        XCTAssertEqual(restored.configuration.subscriptionCostCurrency, "HK$")
    }

    func testCurrencyOnlySaveDoesNotCancelAnInFlightStatisticsRequest() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try configure(f); f.backend.delayStats = 0.15
        f.store.setPanelVisible(true)
        await f.until { f.backend.statsCount == 1 }
        var config = f.store.configuration; config.subscriptionCostCurrency = "元"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertTrue(f.store.isRefreshingSubscriptions)
        await settled(f)
        XCTAssertEqual(f.backend.statsCount, 1)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 100)
        XCTAssertEqual(subscriptionMoney(f.store.totalSubscriptionCost, unit: f.store.configuration.subscriptionCostCurrency), "元200.00")
    }

    func testInvalidCurrencyDoesNotChangeSavedSettingsOrAmounts() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try configure(f)
        await f.open(); await settled(f)
        let original = f.store.configuration
        var invalid = original; invalid.actualCostCurrency = " "
        do { try await f.store.save(invalid, key: "fake-secret"); XCTFail("Expected invalid unit") }
        catch { XCTAssertEqual(error as? SubscriptionError, .invalidCurrencyUnit) }
        XCTAssertEqual(f.store.configuration, original)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 100)
    }

    func testSubscriptionMetadataSavesLocallyAndSurvivesUnpinAndRestart() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try configure(f)
        XCTAssertTrue(f.backend.requests.isEmpty)
        f.store.setPinned(false, id: 1)
        XCTAssertEqual(f.store.subscriptions[1]?.monthlyPrice, 200)
        XCTAssertTrue(f.store.eligibleSubscriptionIDs.isEmpty)
        let restored = AppStore(defaults: f.defaults, credentials: CredentialSession(storage: f.vault), automaticallySchedule: false)
        XCTAssertEqual(restored.subscriptions[1], AccountSubscription(monthlyPrice: 200, renewalDay: 12))
        XCTAssertTrue(restored.pinnedIDs.isEmpty)
        XCTAssertThrowsError(try f.store.saveSubscription(AccountSubscription(monthlyPrice: 20, renewalDay: 12), for: account(3, type: "apikey")))
        XCTAssertThrowsError(try configure(f, price: -1))
        XCTAssertThrowsError(try configure(f, day: 32))
    }

    func testOnlyPinnedCompleteSubscriptionsParticipateInBothTotals() async throws {
        let f = try StoreFixture(ids: [1, 2, 3]); defer { f.cleanup() }
        try configure(f, id: 1)
        try configure(f, id: 2, price: nil)
        try configure(f, id: 3, day: nil)
        try configure(f, id: 4, price: 20)
        await f.open(); await settled(f)
        XCTAssertEqual(f.store.eligibleSubscriptionIDs, [1])
        XCTAssertEqual(f.store.totalSubscriptionCost, 200)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 100)
        XCTAssertEqual(f.backend.statsCount, 1)
        XCTAssertEqual(f.backend.usersCount, 0)
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.store.todayUsage[1], 12, "Standard-price today usage remains independent")
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
    }

    func testExplicitZeroPriceIsIncludedRatherThanMissing() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try configure(f, price: 0)
        await f.open(); await settled(f)
        XCTAssertEqual(f.store.eligibleSubscriptionIDs, [1])
        XCTAssertEqual(f.store.totalSubscriptionCost, 0)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 100)
    }

    func testAdminToggleInvalidatesOldResultsAndKeepsSubscriptionCost() async throws {
        let f = try StoreFixture(interval: 120); defer { f.cleanup() }
        try configure(f)
        await f.open(); await settled(f)
        var config = f.store.configuration; config.includeAdminUsage = false
        let count = f.backend.requests.count
        try await f.store.save(config, key: "fake-secret")
        XCTAssertNil(f.store.totalSubscriptionActualCost)
        XCTAssertEqual(f.store.totalSubscriptionCost, 200)
        XCTAssertEqual(f.backend.requests.count, count, "Saving settings itself must not make network requests")
        await f.tick(0); await settled(f)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 80)
        XCTAssertEqual(f.backend.usersCount, 1)
        XCTAssertEqual(f.backend.statsCount, 3)
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.store.todayUsage[1], 12)
    }

    func testMissingOrFailedAccountStatsNeverBecomePartialTotalOrZero() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        try configure(f, id: 1); try configure(f, id: 2, price: 20)
        f.backend.failedStatsIDs = [2]
        await f.open(); await settled(f)
        XCTAssertEqual(f.store.totalSubscriptionCost, 220)
        XCTAssertNil(f.store.totalSubscriptionActualCost)
        XCTAssertEqual(f.store.subscriptionSample(for: 1)?.actualCost, 100)
        XCTAssertNil(f.store.subscriptionSample(for: 2))
        XCTAssertNotNil(f.store.subscriptionErrors[2])
        XCTAssertEqual(f.store.nextSubscriptionAt, f.date.addingTimeInterval(60))
        f.backend.failedStatsIDs = []
        await f.tick(60); await settled(f)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 200)
    }

    func testFailedAdminDiscoveryFailsClosedButKeepsAccountAndQuotaData() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.store.prepareCredentials()
        var config = f.store.configuration; config.includeAdminUsage = false
        try await f.store.save(config, key: "fake-secret")
        try configure(f); f.backend.usersError = 503
        await f.open(); await settled(f)
        XCTAssertEqual(f.backend.statsCount, 0)
        XCTAssertNil(f.store.totalSubscriptionActualCost)
        XCTAssertNotNil(f.store.subscriptionErrors[1])
        XCTAssertEqual(f.store.concurrency, 1)
        XCTAssertEqual(f.store.snapshots.first?.weeklyCost, 25)
        XCTAssertTrue(f.store.canPoll)
    }

    func testSubscriptionCadenceIsIndependentAndSlowStatsDoNotBlockRuntime() async throws {
        let f = try StoreFixture(interval: 120); defer { f.cleanup() }
        try configure(f)
        await f.open(); await settled(f)
        await f.tick(2)
        XCTAssertEqual(f.backend.statsCount, 1)
        f.backend.delayStats = 0.2; f.backend.actualCost = 150
        f.date = f.date.addingTimeInterval(28); f.store.runDueRefreshes()
        await f.until { f.backend.statsCount == 2 }
        f.backend.concurrency = 4
        await f.tick(2)
        XCTAssertEqual(f.store.concurrency, 4)
        XCTAssertTrue(f.store.isRefreshingSubscriptions)
        await settled(f)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 150)
        XCTAssertEqual(f.backend.batchCount, 1)
        XCTAssertEqual(f.store.nextSubscriptionAt, f.date.addingTimeInterval(30))
    }

    func testNewCycleDoesNotDisplayPreviousCycleCost() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try configure(f)
        await f.open(); await settled(f)
        let old = try XCTUnwrap(f.store.subscriptionCycle(for: 1))
        f.date = old.end
        XCTAssertNil(f.store.totalSubscriptionActualCost)
        f.backend.actualCost = 0
        await f.tick(0); await settled(f)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 0)
        XCTAssertEqual(f.store.subscriptionSample(for: 1)?.cycle.start, old.end)
    }

    func testLateStatsCannotUndoAdminToggleOrCycleEdit() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try configure(f); f.backend.delayStats = 0.3
        f.store.setPanelVisible(true)
        await f.until { f.backend.statsCount == 1 }
        var config = f.store.configuration; config.includeAdminUsage = false
        try await f.store.save(config, key: "fake-secret")
        f.backend.delayStats = 0
        try configure(f, day: 3)
        await f.tick(0); await settled(f)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 80)
        XCTAssertEqual(f.store.subscriptionSample(for: 1)?.cycle.dateString(f.store.subscriptionSample(for: 1)!.cycle.start), "2026-09-03")
        XCTAssertEqual(f.store.subscriptionSample(for: 1)?.includesAdmin, false)
    }

    func testServerAndCredentialChangesClearResultsButKeepLocalMetadataIsolated() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try configure(f)
        await f.open(); await settled(f)
        let original = f.store.configuration
        var config = original; config.serverURL = "https://other.example.invalid"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertTrue(f.store.subscriptions.isEmpty)
        XCTAssertTrue(f.store.subscriptionUsage.isEmpty)
        try configure(f, price: 20)
        try await f.store.save(original, key: "fake-secret")
        XCTAssertEqual(f.store.subscriptions[1]?.monthlyPrice, 200)
        XCTAssertTrue(f.store.subscriptionUsage.isEmpty)
        XCTAssertNil(f.store.totalSubscriptionActualCost)
        try await f.store.save(original, key: "new-secret")
        XCTAssertEqual(f.store.subscriptions[1]?.monthlyPrice, 200)
        XCTAssertTrue(f.store.subscriptionUsage.isEmpty)
    }

    func testClosingCancelsStatsAndAuthenticationFailureStopsAllPolling() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try configure(f); f.backend.delayStats = 0.2
        f.store.setPanelVisible(true)
        await f.until { f.backend.statsCount == 1 }
        f.store.setPanelVisible(false)
        let count = f.backend.requests.count
        await f.tick(60)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(f.backend.requests.count, count)
        XCTAssertTrue(f.store.subscriptionUsage.isEmpty)
        f.backend.delayStats = 0; f.backend.statsError = 401
        f.store.setPanelVisible(true)
        await f.until { f.store.credentialError != nil }
        XCTAssertFalse(f.store.canPoll)
        XCTAssertNil(f.store.nextSubscriptionAt)
    }
}
