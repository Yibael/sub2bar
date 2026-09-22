import AppKit
import SwiftUI
import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class AccountWarningTests: XCTestCase {
    private func apiFixture(ids: [Int] = [1, 2]) throws -> StoreFixture {
        let f = try StoreFixture(ids: ids)
        f.backend.accountOverrides = Dictionary(uniqueKeysWithValues: ids.map { ($0, ["type": "apikey"]) })
        return f
    }

    func testOnlyFailedAccountIsStaleAndTooltipHasNameAndSanitizedReason() async throws {
        let f = try apiFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.failedAccountIDs = [2]
        await f.tick(2)
        XCTAssertNil(f.store.accountReadError(for: 1))
        XCTAssertNotNil(f.store.accountReadError(for: 2))
        XCTAssertNil(f.store.accountReadError(for: 999))
        XCTAssertEqual(f.store.accountWarnings.map(\.id), [2])
        let help = try XCTUnwrap(f.store.accountWarningHelp)
        XCTAssertTrue(help.contains("Account 2 · #2"))
        XCTAssertTrue(help.contains("账号详情"))
        XCTAssertTrue(help.contains("HTTP 503"))
        XCTAssertFalse(help.contains("private-secret-error"))
        XCTAssertFalse(help.contains("Account 1"))
        XCTAssertEqual(f.store.accountOverview.informationalStatusText, "")
        let requests = f.backend.requests.count
        f.store.selectPinned(2)
        _ = f.store.accountWarningHelp
        f.store.selectAdjacentPinned(-1)
        XCTAssertEqual(f.store.selectedPinnedID, 1)
        XCTAssertEqual(f.backend.requests.count, requests, "Hover/selection presentation must never send requests")
        f.backend.failedAccountIDs = []
        await f.tick(4)
        XCTAssertNil(f.store.accountWarningHelp)
        XCTAssertNil(f.store.accountReadError(for: 2))
    }

    func testDailyOnlyFailureDoesNotGreyEitherAccountAndIsScopedToFailedID() async throws {
        let f = try apiFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.missingTodayIDs = [2]
        await f.tick(2)
        XCTAssertNil(f.store.accountReadError(for: 1)); XCTAssertNil(f.store.accountReadError(for: 2))
        XCTAssertEqual(f.store.accountWarnings.map(\.id), [2])
        XCTAssertTrue(try XCTUnwrap(f.store.accountWarningHelp).contains("今日统计"))
        XCTAssertEqual(f.store.accountOverview.failed, 0)
        XCTAssertEqual(f.store.concurrency, 2)
        f.backend.missingTodayIDs = []
        await f.tick(2)
        XCTAssertNil(f.store.accountWarningHelp)
    }

    func testPartialDailyFieldsOnlyFlagTheMissingToken() throws {
        let account = try makeDecoder().decode(Account.self, from: Data(
            #"{"id":2,"name":"API fixture","platform":"openai","type":"apikey","status":"active"}"#.utf8))
        let stats = try makeDecoder().decode(AccountTodayStats.self, from: Data(
            #"{"standard_cost":0,"cost":0,"requests":0}"#.utf8))
        let message = "今日统计未完整"
        for field in [DailyAccountField.standardCost, .accountCost, .requests] {
            XCTAssertNil(field.failure(in: stats, standardCost: stats.standardCost, error: message))
        }
        XCTAssertEqual(DailyAccountField.tokens.failure(in: stats, standardCost: stats.standardCost, error: message), message)
        XCTAssertNil(DailyAccountField.tokens.failure(in: nil, standardCost: nil, error: nil), "Loading is not a failure")
        let warnings = AccountWarning.collect(ids: [2, 2], snapshots: [AccountSnapshot(account: account, usage: nil)],
            directory: [], accountErrors: [:], globalAccountError: nil, dailyErrors: [2: message], dailyStats: [2: stats],
            subscriptionIDs: [], subscriptionErrors: [:], todayActualErrors: [:], at: Date())
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings[0].issues, ["Token：今日统计未完整"])
    }

    func testQuotaAndSubscriptionErrorsAppearWithoutMarkingAccountDetailsFailed() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        await f.open()
        for snapshot in f.store.snapshots {
            try f.store.saveSubscription(AccountSubscription(monthlyPrice: 20, renewalDay: 12), for: snapshot.account)
        }
        await f.until { !f.store.isRefreshingSubscriptions }
        f.backend.failedUsageIDs = [2]
        f.backend.failedStatsIDs = [2]
        await f.tick(30)
        await f.until { !f.store.isRefreshingSubscriptions }
        XCTAssertNil(f.store.accountReadError(for: 1)); XCTAssertNil(f.store.accountReadError(for: 2))
        XCTAssertEqual(f.store.accountWarnings.map(\.id), [2])
        let help = try XCTUnwrap(f.store.accountWarningHelp)
        for label in ["上游额度", "周期消费", "今日实际消费"] { XCTAssertTrue(help.contains(label)) }
        f.backend.failedUsageIDs = []; f.backend.failedStatsIDs = []
        await f.tick(60)
        await f.until { !f.store.isRefreshingSubscriptions }
        XCTAssertNil(f.store.accountWarningHelp)
    }

    func testWarningsAreRemovedOnUnpinAndConnectionChange() async throws {
        let f = try apiFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.failedAccountIDs = [2]
        await f.tick(2)
        f.store.setPanelVisible(false)
        XCTAssertNotNil(f.store.accountWarningHelp)
        f.store.setPinned(false, id: 2)
        XCTAssertNil(f.store.accountWarningHelp)
        var config = f.store.configuration; config.serverURL = "https://other.example.invalid"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertNil(f.store.accountWarningHelp)
    }

    func testAllAccountFailureKeepsSpecificReasonsWithoutDuplicatedCacheMessage() async throws {
        let f = try apiFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.failedAccountIDs = [1, 2]
        await f.tick(2)
        XCTAssertEqual(f.store.accountWarnings.map(\.id), [1, 2])
        XCTAssertEqual(f.store.errorMessage, "账号详情读取失败")
        XCTAssertTrue(f.store.accountWarnings.allSatisfy { $0.issues.contains { $0.contains("HTTP 503") } })
        XCTAssertFalse(try XCTUnwrap(f.store.accountWarningHelp).contains("显示上次结果"))
    }

    func testAuthenticationFailureStillShowsCredentialRecoveryInsteadOfQuietWarningOnly() async throws {
        let f = try apiFixture(); defer { f.cleanup() }
        await f.open()
        f.backend.error = 401
        f.store.refreshManually()
        await f.until { f.store.needsCredentialAccess }
        XCTAssertNotNil(f.store.credentialError)
        XCTAssertFalse(f.store.canPoll)
    }

    func testOperationalQuotaWarningIsStillAvailableInTooltip() async throws {
        let f = try apiFixture(ids: [1]); defer { f.cleanup() }
        f.backend.accountOverrides = [1: ["type": "apikey", "quota_limit": 100, "quota_used": 95]]
        await f.open()
        XCTAssertNil(f.store.accountReadError(for: 1))
        XCTAssertTrue(try XCTUnwrap(f.store.accountWarningHelp).contains("额度接近"))
    }

    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }
    private func save(_ image: CGImage, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["SUB2BAR_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    func testFailureAndRecoveryDoNotAddBannerHeightAndRenderBothAppearances() async throws {
        let f = try apiFixture(); defer { f.cleanup() }
        await f.open()
        f.store.setPanelVisible(false)
        func panel(_ scheme: ColorScheme) -> some View {
            PopoverView(store: f.store, openSettings: {}).background(PreviewPanelBackground())
                .environment(\.colorScheme, scheme)
        }
        var baseline: [String: Int] = [:]
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            let image = try render(panel(scheme)); baseline[name] = image.height
            try save(image, name: "warning-healthy-" + name)
        }
        f.backend.failedAccountIDs = [2]; f.backend.missingTodayIDs = [1]
        await f.open(); f.store.setPanelVisible(false)
        for id in [1, 2] {
            f.store.selectPinned(id)
            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .light ? "light" : "dark"
                let image = try render(panel(scheme))
                XCTAssertEqual(image.height, baseline[name], "Only tooltip/field styling changes, no expanded failure banners")
                try save(image, name: "warning-account-\(id)-" + name)
            }
        }
        f.backend.failedAccountIDs = []; f.backend.missingTodayIDs = []
        await f.open(); f.store.setPanelVisible(false)
        XCTAssertNil(f.store.accountWarningHelp)
        XCTAssertEqual(try render(panel(.light)).height, baseline["light"])
    }

    func testInitialFailedCardAndWarningIndicatorHaveStableGeometry() throws {
        for scheme in [ColorScheme.light, .dark] {
            let short = AccountUnavailableCard(accountID: 1, error: "HTTP 503").frame(width: 396).environment(\.colorScheme, scheme)
            let long = AccountUnavailableCard(accountID: 1, error: String(repeating: "错误原因。", count: 100))
                .frame(width: 396).environment(\.colorScheme, scheme)
            XCTAssertEqual(try render(short).height, try render(long).height)
            let empty = try render(FieldFailureIndicator(message: nil, label: "测试"))
            let failed = try render(FieldFailureIndicator(message: "HTTP 503", label: "测试"))
            XCTAssertEqual(empty.width, failed.width); XCTAssertEqual(empty.height, failed.height)
        }
    }
}
