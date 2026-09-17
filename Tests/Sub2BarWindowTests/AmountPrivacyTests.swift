import AppKit
import SwiftUI
import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class AmountPrivacyTests: XCTestCase {
    func testVisibilityPersistsWithoutChangingDataOrRefreshSchedule() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        await f.open()
        await f.until { !f.store.showsQuotaLoading }
        let requests = f.backend.requests.count
        let deadline = f.store.nextRefreshAt
        let estimate = f.store.estimatedTotal
        XCTAssertFalse(f.store.areAmountsHidden)
        f.store.toggleAmountVisibility()
        XCTAssertTrue(f.store.areAmountsHidden)
        XCTAssertEqual(f.backend.requests.count, requests)
        XCTAssertEqual(f.store.nextRefreshAt, deadline)
        XCTAssertEqual(f.store.estimatedTotal, estimate)
        f.store.setPanelVisible(false)
        XCTAssertTrue(f.store.areAmountsHidden)
        let restored = AppStore(defaults: f.defaults, credentials: CredentialSession(storage: f.vault), automaticallySchedule: false)
        XCTAssertTrue(restored.areAmountsHidden)
        restored.toggleAmountVisibility()
        let visible = AppStore(defaults: f.defaults, credentials: CredentialSession(storage: f.vault), automaticallySchedule: false)
        XCTAssertFalse(visible.areAmountsHidden)
    }

    func testHiddenAccountAndExpandedDetailsDoNotRenderAnyChangedAmounts() throws {
        let date = try XCTUnwrap(parseAPIDate("2026-09-15T10:00:00Z"))
        let cycle = try XCTUnwrap(SubscriptionCycle(renewalDay: 15, at: date, timeZoneID: "UTC"))
        func render(amount: Int, hidden: Bool, expanded: Bool) throws -> Data {
            let account = try makeDecoder().decode(Account.self, from: Data("""
                {"id":1,"name":"Privacy fixture","platform":"openai","type":"oauth","status":"active","quota_weekly_limit":\(amount)}
                """.utf8))
            let stats = try makeDecoder().decode(WindowStats.self, from: Data("{\"cost\":\(amount)}".utf8))
            let usage = UsageInfo(sevenDay: UsageWindow(utilization: 50, windowStats: stats))
            let card = AccountCard(snapshot: AccountSnapshot(account: account, usage: usage), stale: false,
                isPanelVisible: false, todayCost: Double(amount),
                subscription: AccountSubscription(monthlyPrice: Decimal(amount), renewalDay: 15),
                subscriptionCycle: cycle,
                subscriptionSample: SubscriptionUsageSample(cycle: cycle, actualCost: Decimal(amount), includesAdmin: true, sampledAt: date),
                expanded: expanded)
                .frame(width: 396).padding(18).background(PreviewPanelBackground())
                .environment(\.colorScheme, .light).environment(\.sensitiveAmountsHidden, hidden)
            return try bitmap(card)
        }
        for expanded in [false, true] {
            XCTAssertEqual(try render(amount: 123, hidden: true, expanded: expanded),
                           try render(amount: 98765, hidden: true, expanded: expanded),
                           "Every monetary field must disappear, including expanded details")
            XCTAssertNotEqual(try render(amount: 123, hidden: false, expanded: expanded),
                              try render(amount: 98765, hidden: false, expanded: expanded))
        }
    }

    func testHiddenSummaryMasksBothActualConsumptionAndSubscriptionCost() throws {
        func render(amount: Int, hidden: Bool) throws -> Data {
            let metric = ActualCostMetric(title: "周期实际消费", value: Decimal(amount), currency: "¥",
                isConfigured: true, isRefreshing: false, cost: "¥\(amount).00")
                .frame(width: 193).padding(12).background(PreviewPanelBackground())
                .environment(\.colorScheme, .light).environment(\.sensitiveAmountsHidden, hidden)
            return try bitmap(metric)
        }
        XCTAssertEqual(try render(amount: 123, hidden: true), try render(amount: 98765, hidden: true))
        XCTAssertNotEqual(try render(amount: 123, hidden: false), try render(amount: 98765, hidden: false))
    }

    private func bitmap<V: View>(_ view: V) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}
