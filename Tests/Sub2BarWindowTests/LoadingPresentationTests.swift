import AppKit
import SwiftUI
import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class LoadingPresentationTests: XCTestCase {
    func testFirstPresentationShowsLoadingBeforePollingStartsAndDuringAccountFetch() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.store.prepareCredentials()
        f.backend.delayRuntime = 0.2
        XCTAssertEqual(f.store.quotaRefreshLabel(at: f.date), "加载中", "Pre-presentation layout must not say paused")
        XCTAssertTrue(f.backend.requests.isEmpty, "Presentation state must not start requests")
        f.store.setPanelVisible(true)
        XCTAssertFalse(f.store.isRefreshing, "The polling task has not started yet")
        XCTAssertEqual(f.store.quotaRefreshLabel(at: f.date), "加载中")
        XCTAssertEqual(f.store.connectionState, .connecting)
        await f.until { f.store.isRefreshing }
        XCTAssertEqual(f.store.quotaRefreshLabel(at: f.date), "加载中")
        await f.until { f.store.lastUpdated != nil && !f.store.isRefreshing && !f.store.showsQuotaLoading }
        XCTAssertTrue(f.store.quotaRefreshLabel(at: f.date).hasPrefix("额度刷新"))
        f.store.setPanelVisible(false)
        XCTAssertEqual(f.store.quotaRefreshLabel(at: f.date), "已暂停")
    }

    func testInitialFailureDoesNotKeepShowingLoading() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.error = 503
        f.store.setPanelVisible(true)
        await f.until { f.store.errorMessage != nil && !f.store.isRefreshing }
        XCTAssertFalse(f.store.isLoadingInitialAccounts)
        XCTAssertEqual(f.store.quotaRefreshLabel(at: f.date), "等待重试")
        f.store.setPanelVisible(false)
        XCTAssertEqual(f.store.quotaRefreshLabel(at: f.date), "已暂停")
    }

    func testPlaceholderAndAccountStayTheSameHeightWhileIndividualFieldsLoad() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        let snapshot = try XCTUnwrap(f.store.selectedPinnedSnapshot)
        try f.store.saveSubscription(AccountSubscription(monthlyPrice: 1366, renewalDay: 15), for: snapshot.account)
        await f.until { !f.store.isRefreshingSubscriptions }
        let sample = try XCTUnwrap(f.store.subscriptionSample(for: snapshot.id))
        let subscription = f.store.subscriptions[snapshot.id]
        func card(sample: SubscriptionUsageSample?, refreshing: Bool, error: String? = nil) -> AccountCard {
            AccountCard(snapshot: snapshot, stale: false, isPanelVisible: false, todayCost: 12,
                subscription: subscription, subscriptionCycle: sample?.cycle ?? f.store.subscriptionCycle(for: snapshot.id),
                subscriptionSample: sample, subscriptionError: error, isRefreshingSubscription: refreshing)
        }
        let loading = card(sample: nil, refreshing: true)
        XCTAssertTrue(loading.showsSubscriptionLoading)
        XCTAssertFalse(card(sample: sample, refreshing: true).showsSubscriptionLoading, "Refresh must keep the existing amount")
        XCTAssertFalse(card(sample: nil, refreshing: false, error: "统计读取失败").showsSubscriptionLoading)
        let placeholder = try render(AccountLoadingPlaceholder(isLoading: true).frame(width: 396))
        let loaded = try render(card(sample: sample, refreshing: false).frame(width: 396))
        let pending = try render(loading.frame(width: 396))
        XCTAssertEqual(placeholder.height, loaded.height)
        XCTAssertEqual(pending.height, loaded.height)
        let firstSnapshot = AccountSnapshot(account: snapshot.account, usage: nil)
        let allPending = AccountCard(snapshot: firstSnapshot, stale: false, isPanelVisible: false,
            subscription: subscription, subscriptionCycle: sample.cycle,
            isRefreshingTodayUsage: true, isRefreshingQuota: true, isRefreshingSubscription: true)
        XCTAssertEqual(try render(allPending.frame(width: 396)).height, loaded.height)
    }

    func testPanelHeightRemainsStableFromFirstRequestThroughStatisticsCompletion() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.store.prepareCredentials()
        let account = try makeDecoder().decode(Account.self, from: Data(
            #"{"id":1,"name":"Loading fixture","platform":"openai","type":"oauth"}"#.utf8))
        try f.store.saveSubscription(AccountSubscription(monthlyPrice: 1366, renewalDay: 15), for: account)
        f.backend.delayRuntime = 0.4
        f.backend.delayStats = 0.8
        f.backend.delayTodayStats = 0.8
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 432, height: 660),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var reportedHeights: [CGFloat] = []
        let panel = PopoverView(store: f.store, openSettings: {}, version: "0.1.0-beta.2", onHeightChange: { height in
            reportedHeights.append(height)
            DispatchQueue.main.async {
                let currentHeight = window.contentView?.fittingSize.height ?? height
                window.setContentSize(NSSize(width: PanelSizing.width, height: currentHeight))
            }
        }).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: panel)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: PanelSizing.width, height: host.fittingSize.height))
        func capture() throws -> CGImage {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.cgImage)
        }
        f.store.setPanelVisible(true)
        try await Task.sleep(for: .milliseconds(50))
        let initial = try capture()
        await f.until { f.store.selectedPinnedSnapshot != nil && f.store.isRefreshingSubscriptions && !f.store.isRefreshingQuota }
        try await Task.sleep(for: .milliseconds(50))
        let partial = try capture()
        await f.until { !f.store.isRefreshingSubscriptions && !f.store.showsQuotaLoading }
        try await Task.sleep(for: .milliseconds(50))
        let loaded = try capture()
        XCTAssertEqual(initial.height, partial.height)
        XCTAssertEqual(partial.height, loaded.height)
        XCTAssertLessThan(loaded.height, Int(PanelSizing.initialHeight * 2), "The bootstrap height must not appear in the content")
        XCTAssertEqual(Set(reportedHeights).count, 1, "Native layout must not emit intermediate resize requests")
        if let output = ProcessInfo.processInfo.environment["SUB2BAR_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, image) in [("initial-loading", initial), ("statistics-loading", partial), ("loading-complete", loaded)] {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
    }

    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }
}
