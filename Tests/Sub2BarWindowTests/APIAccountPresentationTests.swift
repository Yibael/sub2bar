import AppKit
import SwiftUI
import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class APIAccountPresentationTests: XCTestCase {
    func testTokenCountFormattingKeepsUnknownZeroAndLargeValuesDistinct() {
        XCTAssertEqual(compactTokenCount(nil), "—")
        XCTAssertEqual(compactTokenCount(-1), "—")
        XCTAssertEqual(compactTokenCount(0), "0")
        XCTAssertEqual(compactTokenCount(999), "999")
        XCTAssertEqual(compactTokenCount(1234), "1.23K")
        XCTAssertEqual(compactTokenCount(1234567), "1.23M")
        XCTAssertEqual(compactTokenCount(1234567890), "1.23B")
    }

    private func account(_ fields: [String: Any] = [:]) throws -> Account {
        var json: [String: Any] = ["id": 1, "name": "API 主力账号", "platform": "openai", "type": "apikey",
                                   "status": "active", "schedulable": true, "concurrency": 10, "current_concurrency": 3]
        json.merge(fields) { _, new in new }
        return try makeDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func stats(amount: Int = 12) throws -> AccountTodayStats {
        try makeDecoder().decode(AccountTodayStats.self, from: Data(
            "{\"standard_cost\":\(amount),\"cost\":\(amount),\"user_cost\":\(amount),\"requests\":286,\"tokens\":1234567}".utf8))
    }
    private func image<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }
    private func png(_ image: CGImage) throws -> Data {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    func testEmptyQuotaRegionExactlyMatchesTwoRowsButConfiguredRowsFlowNaturally() throws {
        let all = try account(["quota_daily_limit": 100, "quota_daily_used": 25, "quota_weekly_limit": 500,
                               "quota_weekly_used": 250, "quota_limit": 1000, "quota_used": 500]).localQuotas
        for width in [CGFloat(294), 370] {
            for scheme in [ColorScheme.light, .dark] {
                func render(_ quotas: [AccountQuota], unavailable: Bool = false) throws -> CGImage {
                    try image(LocalQuotaSection(quotas: quotas, unavailable: unavailable).frame(width: width)
                        .environment(\.colorScheme, scheme))
                }
                let empty = try render([]), one = try render(Array(all.prefix(1)))
                let two = try render(Array(all.prefix(2))), three = try render(all)
                XCTAssertEqual(empty.height, two.height)
                XCTAssertEqual(empty.height, Int(PanelSizing.emptyQuotaHeight * 2))
                XCTAssertLessThan(one.height, two.height)
                XCTAssertGreaterThan(three.height, two.height)
                XCTAssertEqual(try render([], unavailable: true).height, empty.height)
                XCTAssertNotEqual(try png(render([], unavailable: true)), try png(empty), "Failure must not look like unconfigured")
            }
        }
    }

    func testAPIAmountsAreHiddenInCollapsedAndExpandedCardsIncludingLocalLimits() throws {
        for expanded in [false, true] {
            func render(amount: Int, hidden: Bool) throws -> Data {
                let value = try account(["quota_limit": amount * 2, "quota_used": amount])
                let card = AccountCard(snapshot: AccountSnapshot(account: value, usage: nil), stale: false,
                    isPanelVisible: false, todayCost: Double(amount), todayStats: try stats(amount: amount),
                    expanded: expanded)
                    .frame(width: 396).padding(18).background(PreviewPanelBackground())
                    .environment(\.colorScheme, .light).environment(\.sensitiveAmountsHidden, hidden)
                return try png(image(card))
            }
            XCTAssertEqual(try render(amount: 123, hidden: true), try render(amount: 98765, hidden: true))
            XCTAssertNotEqual(try render(amount: 123, hidden: false), try render(amount: 98765, hidden: false))
        }
    }

    func testAPIThreeColumnRowsKeepTheirSizeWhileStatisticsLoad() throws {
        let snapshot = AccountSnapshot(account: try account(), usage: nil)
        let complete = try stats()
        let missingToken = try makeDecoder().decode(AccountTodayStats.self, from: Data(
            #"{"standard_cost":12,"cost":12,"requests":286}"#.utf8))
        for width in [CGFloat(320), 396] {
            var heights: [Int] = []
            for sample in [nil, missingToken, complete] as [AccountTodayStats?] {
                let card = AccountCard(snapshot: snapshot, stale: false, isPanelVisible: false,
                    todayCost: sample?.standardCost, todayStats: sample, isRefreshingTodayUsage: sample == nil)
                    .frame(width: width).environment(\.colorScheme, .light)
                let rendered = try image(card)
                XCTAssertEqual(rendered.width, Int(width * 2))
                heights.append(rendered.height)
            }
            XCTAssertEqual(Set(heights).count, 1, "Loading and missing Token values must not reflow the 3+1 rows")
        }
    }

    func testAPITokenRowMatchesOAuthSubscriptionRowHeight() throws {
        let api = AccountSnapshot(account: try account(), usage: nil)
        let oauth = AccountSnapshot(account: try account(["type": "oauth"]), usage:
            UsageInfo(fiveHour: UsageWindow(utilization: 0), sevenDay: UsageWindow(utilization: 44)))
        let complete = try stats()
        for width in [CGFloat(320), 396] {
            for scheme in [ColorScheme.light, .dark] {
                for loading in [false, true] {
                    let apiCard = AccountCard(snapshot: api, stale: false, isPanelVisible: false,
                        todayCost: loading ? nil : complete.standardCost, todayStats: loading ? nil : complete,
                        isRefreshingTodayUsage: loading)
                        .frame(width: width).environment(\.colorScheme, scheme)
                    let oauthCard = AccountCard(snapshot: oauth, stale: false, isPanelVisible: false,
                        todayCost: loading ? nil : complete.standardCost,
                        subscription: AccountSubscription(monthlyPrice: 200, renewalDay: 15),
                        isRefreshingTodayUsage: loading, isRefreshingSubscription: loading)
                        .frame(width: width).environment(\.colorScheme, scheme)
                    XCTAssertEqual(try image(apiCard).height, try image(oauthCard).height,
                        "Unconfigured API quotas and two OAuth quota rows must keep card height stable when switching")
                }
            }
        }
    }

    func testAccountCardsRenderAllQuotaAndFailureStatesInBothAppearances() throws {
        let fields: [(String, [String: Any], Bool)] = [
            ("api-no-quota", [:], false),
            ("api-weekly", ["quota_weekly_limit": 500, "quota_weekly_used": 310], false),
            ("api-all-quotas", ["quota_daily_limit": 100, "quota_daily_used": 24,
                               "quota_weekly_limit": 500, "quota_weekly_used": 310,
                               "quota_limit": 1000, "quota_used": 380], false),
            ("api-unknown-used", ["quota_daily_limit": 100], false),
            ("api-stale", ["quota_weekly_limit": 500, "quota_weekly_used": 310], true),
            ("api-stale-no-quota", [:], true),
            ("oauth-control", ["type": "oauth"], false)
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, extra, stale) in fields {
                let value = try account(extra)
                let snapshot = AccountSnapshot(account: value, usage: value.supportsUsageQuery ?
                    UsageInfo(fiveHour: UsageWindow(utilization: 35), sevenDay: UsageWindow(utilization: 62)) : nil)
                for expanded in [false, true] {
                    let card = AccountCard(snapshot: snapshot, stale: stale, isPanelVisible: false, todayCost: 18.60,
                        todayStats: try stats(), accountReadError: stale ? "账号读取失败" : nil,
                        accountUpdatedAt: parseAPIDate("2026-09-22T03:00:00Z"), expanded: expanded)
                        .frame(width: 396).padding(18).background(PreviewPanelBackground())
                        .environment(\.colorScheme, scheme)
                    let rendered = try image(card)
                    XCTAssertEqual(rendered.width, 864)
                    XCTAssertGreaterThanOrEqual(rendered.height, 424)
                    if let output = ProcessInfo.processInfo.environment["SUB2BAR_RENDER_DIR"] {
                        let directory = URL(fileURLWithPath: output, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let suffix = "\(scheme == .light ? "light" : "dark")-\(expanded ? "expanded" : "collapsed")"
                        try png(rendered).write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
                    }
                }
            }
        }
    }
}
