import AppKit
import Combine
import SwiftUI
import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class NavigationResponsivenessTests: XCTestCase {
    func testSelectionDoesNotInvalidateDashboardStoreOrPublishNoOpSelections() throws {
        let f = try StoreFixture(ids: [1, 2, 3]); defer { f.cleanup() }
        var dashboardChanges = 0, pageChanges = 0
        let dashboard = f.store.objectWillChange.sink { dashboardChanges += 1 }
        let page = f.store.navigation.objectWillChange.sink { pageChanges += 1 }
        defer { dashboard.cancel(); page.cancel() }
        f.store.selectPinned(1)
        XCTAssertEqual(pageChanges, 0)
        for _ in 0..<90 { f.store.selectAdjacentPinned(1) }
        XCTAssertEqual(pageChanges, 90)
        XCTAssertEqual(dashboardChanges, 0, "Account selection must not rebuild all-account aggregates")
        XCTAssertTrue(f.backend.requests.isEmpty)
    }

    func testInitialSlowRequestsDoNotDelaySelectionAndShowSelectedAccountPlaceholder() async throws {
        let f = try StoreFixture(ids: [1, 2, 3]); defer { f.cleanup() }
        f.backend.delayRuntime = 1; f.backend.delayToday = 1
        f.store.setPanelVisible(true)
        await f.until { f.backend.detailCount == 3 && f.backend.todayCount == 1 }
        let requestCount = f.backend.requests.count
        f.store.selectAdjacentPinned(1)
        XCTAssertEqual(f.store.selectedPinnedID, 2, "No await is needed to commit a selection")
        XCTAssertNil(f.store.selectedPinnedSnapshot)
        XCTAssertTrue(f.store.isRefreshing)
        XCTAssertEqual(f.backend.requests.count, requestCount)
        let view = PinnedAccountPage(store: f.store, navigation: f.store.navigation).frame(width: 396)
        XCTAssertNotNil(ImageRenderer(content: view).cgImage, "The new page can draw before requests finish")
        XCTAssertEqual(f.store.selectedPinnedID, 2)
        XCTAssertNil(f.store.selectedPinnedSnapshot)
    }

    func testCachedPageSwitchesWhileAllThreePollingLanesAreStillRunning() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        await f.open()
        for snapshot in f.store.snapshots {
            try f.store.saveSubscription(AccountSubscription(monthlyPrice: 20, renewalDay: 12), for: snapshot.account)
        }
        await f.until { !f.store.isRefreshingSubscriptions }
        f.backend.delayRuntime = 1; f.backend.delayToday = 1
        f.backend.delayActive = 1; f.backend.delayStats = 1
        f.store.refreshManually()
        await f.until { f.store.isRefreshing && f.store.isRefreshingQuota && f.store.isRefreshingSubscriptions }
        let quotaDeadline = f.store.nextRefreshAt
        f.store.selectAdjacentPinned(1)
        XCTAssertEqual(f.store.selectedPinnedID, 2)
        XCTAssertEqual(f.store.selectedPinnedSnapshot?.id, 2)
        XCTAssertNotNil(f.store.todayStats[2])
        XCTAssertTrue(f.store.isRefreshing && f.store.isRefreshingQuota && f.store.isRefreshingSubscriptions)
        XCTAssertEqual(f.store.nextRefreshAt, quotaDeadline)
    }

    func testCompletePollPublishesOneSnapshotPerLaneNotPerAccount() async throws {
        let f = try StoreFixture(ids: Array(1...20)); defer { f.cleanup() }
        var counts: [Int] = []
        let observation = f.store.$snapshots.dropFirst().sink { counts.append($0.count) }
        defer { observation.cancel() }
        await f.open()
        XCTAssertEqual(counts, [20, 20], "Runtime and quota batches each commit one complete update")
    }

    func testLiveHostingViewSwitchesWithoutRecreatingRootOrRequestingData() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        f.backend.accountOverrides = [1: ["type": "apikey"], 2: ["type": "apikey"]]
        await f.open()
        f.store.setPanelVisible(false)
        let count = f.backend.requests.count
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 432, height: 660),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PopoverView(store: f.store, openSettings: {}).environment(\.colorScheme, .light))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 432, height: host.fittingSize.height))
        func capture() throws -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        try await Task.sleep(for: .milliseconds(20))
        let first = try capture()
        f.store.selectAdjacentPinned(1)
        try await Task.sleep(for: .milliseconds(20))
        let second = try capture()
        XCTAssertNotEqual(first, second, "The visible title/pager must update through the isolated selection observable")
        f.store.selectAdjacentPinned(-1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(first, try capture(), "Switching back restores the same rendered content")
        XCTAssertEqual(f.backend.requests.count, count)
    }
}
