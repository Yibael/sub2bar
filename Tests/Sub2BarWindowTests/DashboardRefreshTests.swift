import AppKit
import SwiftUI
import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class DashboardRefreshTests: XCTestCase {
    private func configure(_ f: StoreFixture, ids: [Int] = [1]) async throws {
        await f.store.prepareCredentials()
        for id in ids {
            let account = try makeDecoder().decode(Account.self, from: Data(
                "{\"id\":\(id),\"name\":\"Account \(id)\",\"platform\":\"openai\",\"type\":\"oauth\"}".utf8))
            try f.store.saveSubscription(AccountSubscription(monthlyPrice: 20, renewalDay: 12), for: account)
        }
    }

    private func settle(_ f: StoreFixture) async {
        await f.until { !f.store.isRefreshing && !f.store.isRefreshingQuota && !f.store.isRefreshingSubscriptions }
    }

    func testInitialLoadingThenIndependentRefreshKeepsValuesUntilEachLaneCompletes() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try await configure(f)
        XCTAssertTrue(f.store.concurrencySummary.showsLoading)
        XCTAssertTrue(f.store.estimateSummary.showsLoading)
        XCTAssertTrue(f.store.actualCostSummary(today: true).showsLoading)
        XCTAssertTrue(f.store.actualCostSummary(today: false).showsLoading)
        await f.open(); await settle(f)
        let concurrency = try XCTUnwrap(f.store.concurrencySummary.value)
        let estimate = try XCTUnwrap(f.store.estimateSummary.value)
        let today = try XCTUnwrap(f.store.actualCostSummary(today: true).value)
        let cycle = try XCTUnwrap(f.store.actualCostSummary(today: false).value)
        f.backend.concurrency = 4; f.backend.usageCost = 50
        f.backend.todayActualCost = 40; f.backend.actualCost = 120
        f.backend.delayRuntime = 0.1; f.backend.delayToday = 0.6
        f.backend.delayActive = 0.4; f.backend.delayStats = 0.4; f.backend.delayTodayStats = 0.4
        f.date = f.date.addingTimeInterval(30); f.store.runDueRefreshes()
        XCTAssertEqual(f.store.concurrencySummary.value, concurrency)
        XCTAssertEqual(f.store.estimateSummary.value, estimate)
        XCTAssertEqual(f.store.actualCostSummary(today: true).value, today)
        XCTAssertEqual(f.store.actualCostSummary(today: false).value, cycle)
        XCTAssertTrue(f.store.concurrencySummary.showsRefreshIndicator)
        XCTAssertTrue(f.store.estimateSummary.showsRefreshIndicator)
        XCTAssertTrue(f.store.actualCostSummary(today: true).showsRefreshIndicator)
        XCTAssertTrue(f.store.actualCostSummary(today: false).showsRefreshIndicator)
        await f.until { !f.store.isRefreshingAccountSummary }
        XCTAssertEqual(f.store.concurrencySummary.value, DashboardConcurrency(count: 4, limit: 5))
        XCTAssertFalse(f.store.concurrencySummary.showsRefreshIndicator)
        XCTAssertTrue(f.store.isRefreshing, "Slow daily standard usage must not keep concurrency spinning")
        XCTAssertEqual(f.store.estimateSummary.value, estimate)
        XCTAssertEqual(f.store.actualCostSummary(today: true).value, today)
        await settle(f)
        XCTAssertEqual(f.store.estimateSummary.value, 100)
        XCTAssertEqual(f.store.actualCostSummary(today: true).value?.amount, 40)
        XCTAssertEqual(f.store.actualCostSummary(today: false).value,
                       DashboardActualCost(amount: 120, subscriptionCost: 20))
        XCTAssertFalse(f.store.estimateSummary.showsRefreshIndicator)
        XCTAssertFalse(f.store.actualCostSummary(today: true).showsRefreshIndicator)
        XCTAssertFalse(f.store.actualCostSummary(today: false).showsRefreshIndicator)
    }

    func testPartialFailureRetainsWholeAggregateAndSuccessfulCardsUpdate() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        try await configure(f, ids: [1, 2]); await f.open(); await settle(f)
        let today = f.store.actualCostSummary(today: true).value
        let estimate = f.store.estimateSummary.value
        f.backend.todayActualCost = 60; f.backend.actualCost = 150
        f.backend.failedTodayStatsIDs = [2]; f.backend.failedUsageIDs = [2]
        f.backend.usageCost = 100
        await f.tick(30); await settle(f)
        XCTAssertNil(f.store.totalTodayActualCost, "Raw statistics must retain their existing validity rules")
        XCTAssertEqual(f.store.actualCostSummary(today: true).value, today)
        XCTAssertEqual(f.store.actualCostSummary(today: true).failureHelp, "更新失败，当前显示上次结果")
        XCTAssertEqual(f.store.actualCostSummary(today: false).value?.amount, 300)
        XCTAssertNil(f.store.actualCostSummary(today: false).failureHelp)
        XCTAssertEqual(f.store.estimateSummary.value, estimate, "Never mix a new account estimate with a failed old one")
        XCTAssertNotNil(f.store.estimateSummary.failureHelp)
        XCTAssertFalse(f.store.actualCostSummary(today: true).showsLoading)
        f.backend.failedTodayStatsIDs = []; f.backend.failedUsageIDs = []
        await f.tick(60); await settle(f)
        XCTAssertEqual(f.store.actualCostSummary(today: true).value?.amount, 120)
        XCTAssertNil(f.store.actualCostSummary(today: true).failureHelp)
        XCTAssertEqual(f.store.estimateSummary.value, 400)
        XCTAssertNil(f.store.estimateSummary.failureHelp)
    }

    func testTotalFailureRetainsAllFourCardsAndInitialFailureStopsLoading() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        try await configure(f); await f.open(); await settle(f)
        f.backend.error = 503
        await f.tick(30); await settle(f)
        XCTAssertEqual(f.store.concurrencySummary.value?.count, 1)
        XCTAssertEqual(f.store.estimateSummary.value, 50)
        XCTAssertEqual(f.store.actualCostSummary(today: true).value?.amount, 30)
        XCTAssertEqual(f.store.actualCostSummary(today: false).value?.amount, 100)
        XCTAssertNotNil(f.store.concurrencySummary.failureHelp)
        XCTAssertNotNil(f.store.estimateSummary.failureHelp)
        XCTAssertNotNil(f.store.actualCostSummary(today: true).failureHelp)
        XCTAssertNotNil(f.store.actualCostSummary(today: false).failureHelp)
        f.store.setPanelVisible(false)

        let first = try StoreFixture(); defer { first.cleanup() }
        try await configure(first); first.backend.statsError = 503; first.backend.usageError = 503
        await first.open(); await settle(first)
        XCTAssertNil(first.store.actualCostSummary(today: true).value)
        XCTAssertFalse(first.store.actualCostSummary(today: true).showsLoading)
        XCTAssertEqual(first.store.actualCostSummary(today: true).failureHelp, "加载失败，等待重试")
        XCTAssertNil(first.store.estimateSummary.value)
        XCTAssertFalse(first.store.estimateSummary.showsLoading)
    }

    func testScopeChangesNeverReuseUnrelatedNumbersButPagingDoes() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        try await configure(f, ids: [1, 2]); await f.open(); await settle(f)
        let today = f.store.actualCostSummary(today: true).value
        f.backend.delayTodayStats = 0.2
        f.date = f.date.addingTimeInterval(30); f.store.runDueRefreshes()
        f.store.selectAdjacentPinned(1); f.store.movePinned(2, by: -1)
        XCTAssertEqual(f.store.actualCostSummary(today: true).value, today)
        await settle(f)
        f.date = f.date.addingTimeInterval(86_400)
        f.store.runDueRefreshes()
        XCTAssertNil(f.store.actualCostSummary(today: true).value, "Yesterday is not a cache of today")
        XCTAssertTrue(f.store.actualCostSummary(today: true).showsLoading)
        XCTAssertEqual(f.store.actualCostSummary(today: false).value?.amount, 200)
        await settle(f)
        var config = f.store.configuration; config.includeAdminUsage.toggle()
        try await f.store.save(config, key: "fake-secret")
        XCTAssertNil(f.store.actualCostSummary(today: true).value)
        XCTAssertNil(f.store.actualCostSummary(today: false).value)
        f.store.runDueRefreshes(); await settle(f)
        f.backend.delayRuntime = 0.2
        f.store.setPinned(true, id: 3)
        XCTAssertNil(f.store.concurrencySummary.value, "A new Pin set must not reuse the old aggregate")
        await settle(f)
        try await f.store.save(config, key: "new-secret")
        XCTAssertNil(f.store.concurrencySummary.value)
        XCTAssertNil(f.store.estimateSummary.value)
        XCTAssertNil(f.store.actualCostSummary(today: true).value)
        XCTAssertNil(f.store.actualCostSummary(today: false).value)
    }

    func testZeroIsACompleteValueAndFailurePreservesPairedNumbers() {
        let scope = DashboardMetricScope(connection: UUID(), accountIDs: [1])
        var cache = DashboardMetricCache<DashboardActualCost>()
        let zero = DashboardActualCost(amount: 0, subscriptionCost: 20)
        cache.record(zero, in: scope, failed: false)
        cache.record(DashboardActualCost(amount: 8, subscriptionCost: 40), in: scope, failed: true)
        XCTAssertEqual(cache.value(in: scope), zero)
        let state = DashboardMetricState(value: cache.value(in: scope), isRefreshing: true, failed: false)
        XCTAssertFalse(state.showsLoading)
        XCTAssertTrue(state.showsRefreshIndicator)
        var newScope = scope; newScope.subscriptions = [1: AccountSubscription(monthlyPrice: 40, renewalDay: 20)]
        XCTAssertNil(cache.value(in: newScope))
    }

    func testPinRemovalUsesOnlyRemainingSamplesAndKeepsThemOnRefreshAndCancellation() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        try await configure(f, ids: [1, 2]); await f.open(); await settle(f)
        f.store.setPanelVisible(false)
        f.store.setPinned(false, id: 2)
        XCTAssertEqual(f.store.concurrencySummary.value?.count, 1)
        XCTAssertEqual(f.store.estimateSummary.value, 50)
        XCTAssertEqual(f.store.actualCostSummary(today: true).value?.amount, 30)
        XCTAssertEqual(f.store.actualCostSummary(today: false).value?.amount, 100)
        f.backend.delayRuntime = 0.4; f.backend.delayActive = 0.4
        f.backend.delayStats = 0.4; f.backend.delayTodayStats = 0.4
        f.date = f.date.addingTimeInterval(30)
        f.store.setPanelVisible(true)
        await f.until { f.store.isRefreshingAccountSummary && f.store.isRefreshingQuota && f.store.isRefreshingSubscriptions }
        XCTAssertEqual(f.store.concurrencySummary.value?.count, 1)
        XCTAssertEqual(f.store.estimateSummary.value, 50)
        XCTAssertEqual(f.store.actualCostSummary(today: true).value?.amount, 30)
        XCTAssertEqual(f.store.actualCostSummary(today: false).value?.amount, 100)
        f.store.setPanelVisible(false)
        XCTAssertFalse(f.store.concurrencySummary.showsRefreshIndicator)
        XCTAssertFalse(f.store.estimateSummary.showsRefreshIndicator)
        XCTAssertFalse(f.store.actualCostSummary(today: true).showsRefreshIndicator)
        XCTAssertEqual(f.store.actualCostSummary(today: true).value?.amount, 30)
    }

    func testCornerSpinnerIsDelayedCancelledAndDoesNotChangeCardSize() async throws {
        func metric(_ refreshing: Bool, failureHelp: String? = nil) -> some View {
            ActualCostMetric(title: "周期实际消费", value: 530.74, currency: "¥", isConfigured: true,
                             isRefreshing: refreshing, cost: "¥1,366.00", failureHelp: failureHelp).frame(width: 193)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 193, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: metric(false))
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        func spinnerCount(_ view: NSView) -> Int {
            (view is NSProgressIndicator ? 1 : 0) + view.subviews.reduce(0) { $0 + spinnerCount($1) }
        }
        host.rootView = metric(true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(spinnerCount(host), 0)
        host.rootView = metric(false)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(spinnerCount(host), 0, "A cancelled delay must not show a late spinner")
        host.rootView = metric(true)
        try await Task.sleep(for: .milliseconds(280))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(spinnerCount(host), 1)
        XCTAssertEqual(host.fittingSize, size)
        if let output = ProcessInfo.processInfo.environment["SUB2BAR_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("summary-refresh.png"))
        }
        host.rootView = metric(false, failureHelp: "更新失败，当前显示上次结果")
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(spinnerCount(host), 0)
        XCTAssertEqual(host.fittingSize, size)
    }
}
