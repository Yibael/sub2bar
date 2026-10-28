import AppKit
import SwiftUI
import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class GlobalDashboardTests: XCTestCase {
    private func settle(_ f: StoreFixture) async {
        await f.until { !f.store.dashboard.refreshingCosts && !f.store.dashboard.refreshingConcurrency &&
            !f.store.isRefreshing && !f.store.isRefreshingQuota && !f.store.isRefreshingSubscriptions }
    }
    private func open(_ f: StoreFixture) async {
        if f.store.pinCount == 0 { f.store.setPanelVisible(true) }
        else { await f.open() }
        await f.until { f.globalBackend.globalStatsCount >= 2 }
        await settle(f)
    }

    func testGlobalDashboardWorksWithoutPinsOrSubscriptions() async throws {
        let f = try StoreFixture(ids: []); defer { f.cleanup() }
        await open(f)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30)
        XCTAssertEqual(f.store.dashboard.cost(.todayStandard).value, 999)
        XCTAssertEqual(f.store.dashboard.cost(.thirtyDaysActual).value, 100)
        XCTAssertEqual(f.store.dashboard.concurrencyState.value?.count, 3)
        XCTAssertEqual(f.store.dashboard.concurrencyState.value?.limit, 75)
        XCTAssertEqual(f.store.connectionState, .connected)
        XCTAssertTrue(f.backend.requests.isEmpty)
        XCTAssertEqual(f.globalBackend.statsCount, 2)
        XCTAssertTrue(f.globalBackend.requests.allSatisfy { !$0.contains("account_id=") })
    }

    func testAPIAccountsGetTodayActualAndStandardWithoutSubscriptionAndFollowAdminSwitch() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        f.backend.accountOverrides = [1: ["type": "apikey"], 2: ["type": "bedrock"]]
        await open(f)
        XCTAssertTrue(f.store.eligibleSubscriptionIDs.isEmpty)
        XCTAssertEqual(f.backend.batchCount, 0)
        XCTAssertEqual(f.store.dashboard.costs(for: 1)?.totalActualCost, 30)
        XCTAssertEqual(f.store.dashboard.costs(for: 2)?.totalCost, 999)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30, "Global total must not sum pins")
        let quota = f.backend.batchCount, concurrency = f.globalBackend.concurrencyCount
        f.store.setAdminExcluded(true)
        XCTAssertNil(f.store.dashboard.cost(.todayActual).value)
        XCTAssertNil(f.store.dashboard.cost(.todayStandard).value)
        XCTAssertNil(f.store.dashboard.costs(for: 1))
        await settle(f)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 25)
        XCTAssertEqual(f.store.dashboard.cost(.todayStandard).value, 0)
        XCTAssertEqual(f.store.dashboard.cost(.thirtyDaysActual).value, 80)
        XCTAssertEqual(f.store.dashboard.costs(for: 1)?.totalActualCost, 25)
        XCTAssertEqual(f.store.dashboard.costs(for: 2)?.totalCost, 0)
        XCTAssertEqual(f.globalBackend.usersCount, 1, "All global and account daily costs share Admin lookup")
        XCTAssertEqual(f.backend.batchCount, quota)
        XCTAssertEqual(f.globalBackend.concurrencyCount, concurrency)
        let saved = try JSONDecoder().decode(Configuration.self, from: XCTUnwrap(f.defaults.data(forKey: "sub2bar.configuration.v1")))
        XCTAssertFalse(saved.includeAdminUsage)
    }

    func testNavigationAndSubscriptionEditsDoNotChangeGlobalScopeOrTriggerRequests() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        await open(f)
        let requests = f.globalBackend.requests.count
        f.store.selectAdjacentPinned(1); f.store.movePinned(2, by: -1)
        try f.store.saveSubscription(AccountSubscription(monthlyPrice: 20, renewalDay: 12),
                                     for: XCTUnwrap(f.store.snapshots.first?.account))
        await settle(f)
        XCTAssertEqual(f.globalBackend.requests.count, requests)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30)
        f.store.setPinned(false, id: 1)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30)
        await settle(f)
        XCTAssertNil(f.store.dashboard.costs(for: 1))
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30)
    }

    func testFailedGlobalMetricsKeepOnlySameScopeValuesAndRecoverIndependently() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await open(f)
        f.globalBackend.todayStatsError = 503; f.globalBackend.actualCost = 500
        f.store.refreshManually(); await settle(f)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30)
        XCTAssertNotNil(f.store.dashboard.cost(.todayActual).failureHelp)
        XCTAssertEqual(f.store.dashboard.cost(.todayStandard).value, 999)
        XCTAssertEqual(f.store.dashboard.cost(.thirtyDaysActual).value, 500)
        XCTAssertNil(f.store.dashboard.cost(.thirtyDaysActual).failureHelp)
        XCTAssertNil(f.store.dashboard.costs(for: 1)?.totalActualCost)
        f.store.setAdminExcluded(true); await settle(f)
        XCTAssertNil(f.store.dashboard.cost(.todayActual).value)
        XCTAssertNotNil(f.store.dashboard.cost(.todayActual).failureHelp)
        XCTAssertEqual(f.store.dashboard.cost(.thirtyDaysActual).value, 480)
        f.globalBackend.todayStatsError = 0
        f.store.refreshManually(); await settle(f)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 25)
        XCTAssertNil(f.store.dashboard.cost(.todayActual).failureHelp)
    }

    func testLateResponseCannotUndoAdminToggleAndMidnightInvalidatesBothPeriods() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.store.prepareCredentials()
        var config = f.store.configuration; config.subscriptionTimeZoneID = "Asia/Shanghai"
        try await f.store.save(config, key: "fake-secret")
        f.date = parseAPIDate("2026-10-28T15:59:59Z")!
        f.globalBackend.delayTodayStats = 0.15
        await f.open(); await f.until { f.globalBackend.globalStatsCount >= 2 }
        f.globalBackend.delayTodayStats = 0
        f.globalBackend.todayActualCost = 50
        f.store.setAdminExcluded(true); await settle(f)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 45)
        f.date = f.date.addingTimeInterval(1)
        XCTAssertNil(f.store.dashboard.cost(.todayActual).value)
        XCTAssertNil(f.store.dashboard.cost(.todayStandard).value)
        XCTAssertNil(f.store.dashboard.cost(.thirtyDaysActual).value)
        XCTAssertNil(f.store.dashboard.costs(for: 1))
        f.store.refreshManually(); await settle(f)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 45)
        XCTAssertTrue(f.globalBackend.requests.contains { $0.contains("start_date=2026-09-30") && $0.contains("end_date=2026-10-29") })
    }

    func testConnectionChangeAndGlobalAuthenticationFailureStopAndIsolateAllData() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await open(f)
        f.globalBackend.todayStatsError = 401
        f.store.refreshManually()
        await f.until { f.store.credentialError != nil }
        XCTAssertFalse(f.store.canPoll)
        XCTAssertFalse(f.store.dashboard.refreshingCosts)
        let count = f.globalBackend.requests.count
        await f.tick(120)
        XCTAssertEqual(f.globalBackend.requests.count, count)
        f.globalBackend.todayStatsError = 0
        var config = f.store.configuration; config.serverURL = "https://other.example.invalid"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertNil(f.store.dashboard.cost(.todayActual).value)
        XCTAssertNil(f.store.dashboard.concurrencyState.value)
        XCTAssertEqual(f.globalBackend.requests.count, count, "Saving a new connection must not connect")
    }

    func testClosedPanelAndIntervalEditsPreserveBackoffWithoutExtraQuotaRequests() async throws {
        let f = try StoreFixture(statisticsInterval: 30); defer { f.cleanup() }
        f.globalBackend.todayStatsError = 503
        await open(f)
        let requests = f.globalBackend.statsCount
        var config = f.store.configuration; config.statisticsRefreshInterval = 2
        try await f.store.save(config, key: "fake-secret")
        await f.tick(2); await settle(f)
        XCTAssertEqual(f.globalBackend.statsCount, requests)
        f.store.setPanelVisible(false)
        let allRequests = f.globalBackend.requests.count
        await f.tick(120)
        XCTAssertEqual(f.globalBackend.requests.count, allRequests)
        f.globalBackend.todayStatsError = 0
        await open(f)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30)
    }

    func testSettingsDoNotDispatchDueGlobalRequestsAndPreserveInflightStatistics() async throws {
        let f = try StoreFixture(statisticsInterval: 30); defer { f.cleanup() }
        await open(f)
        f.date = f.date.addingTimeInterval(10)
        let count = f.globalBackend.requests.count
        var config = f.store.configuration; config.statisticsRefreshInterval = 2
        try await f.store.save(config, key: "fake-secret")
        await Task.yield()
        XCTAssertEqual(f.globalBackend.requests.count, count, "Saving only reschedules; it must not query directly")
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30)
        f.globalBackend.delayTodayStats = 0.15
        f.globalBackend.todayActualCost = 80
        f.store.runDueRefreshes()
        await f.until { f.store.dashboard.refreshingCosts && f.globalBackend.statsCount > 3 }
        config.actualCostCurrency = "¥"; config.statisticsRefreshInterval = 5
        try await f.store.save(config, key: "fake-secret")
        XCTAssertTrue(f.store.dashboard.refreshingCosts)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30)
        await settle(f)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 80)
        let finished = f.globalBackend.statsCount
        await f.tick(4); await settle(f)
        XCTAssertEqual(f.globalBackend.statsCount, finished)
        await f.tick(1); await settle(f)
        XCTAssertGreaterThan(f.globalBackend.statsCount, finished)
    }

    func testCloseAndServerChangeDiscardLateGlobalResponses() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.globalBackend.delayTodayStats = 0.15
        await f.open(); await f.until { f.globalBackend.globalStatsCount >= 2 }
        f.store.setPanelVisible(false)
        let count = f.globalBackend.requests.count
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(f.store.dashboard.cost(.todayActual).value)
        XCTAssertEqual(f.globalBackend.requests.count, count)
        f.globalBackend.delayTodayStats = 0
        await open(f)
        XCTAssertEqual(f.store.dashboard.cost(.todayActual).value, 30)
        f.globalBackend.delayTodayStats = 0.15; f.globalBackend.todayActualCost = 500
        f.store.refreshManually(); await f.until { f.store.dashboard.refreshingCosts }
        var config = f.store.configuration; config.serverURL = "https://other.example.invalid"
        try await f.store.save(config, key: "fake-secret")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(f.store.dashboard.cost(.todayActual).value)
        XCTAssertNil(f.store.dashboard.concurrencyState.value)
        XCTAssertFalse(f.store.dashboard.refreshingCosts)
    }

    func testPanelRendersGlobalCardsAndAPICostsInBothAppearances() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.accountOverrides = [1: ["type": "apikey"]]
        await open(f)
        var widths: [Int] = []
        for scheme in [ColorScheme.light, .dark] {
            let view = PopoverView(store: f.store, openSettings: {}, version: "0.1.1")
                .background(PreviewPanelBackground()).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 432, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            widths.append(Int(host.bounds.width))
            if let output = ProcessInfo.processInfo.environment["SUB2BAR_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("global-dashboard-\(scheme == .light ? "light" : "dark").png"))
            }
            window.close()
        }
        XCTAssertEqual(widths, [432, 432])
    }
}
