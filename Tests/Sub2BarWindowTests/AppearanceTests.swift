import AppKit
import SwiftUI
import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class AppearanceTests: XCTestCase {
    func testNeutralPanelBackgroundBlocksBlueAndRedInLightAndDark() throws {
        for scheme in [ColorScheme.light, .dark] {
            for underlying in [Color.blue, Color.red] {
                let view = ZStack { underlying; NeutralPanelBackground() }
                    .frame(width: 40, height: 40).environment(\.colorScheme, scheme)
                let image = try XCTUnwrap(ImageRenderer(content: view).cgImage)
                let bitmap = NSBitmapImageRep(cgImage: image)
                for point in [(10, 5), (10, 20), (10, 35)] {
                    let color = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.005)
                    XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.005)
                    XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
                }
            }
        }
    }

    // Offscreen render artifacts use test-only data, never production demo code.
    func testSettingsAndPanelCanRenderOffscreen() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        f.backend.usagePercentage = 98
        f.backend.concurrency = 3
        await f.open()
        let subscriptionAccount = try XCTUnwrap(f.store.snapshots.first?.account)
        try f.store.saveSubscription(AccountSubscription(monthlyPrice: 200, renewalDay: 12), for: subscriptionAccount)
        await f.until { !f.store.isRefreshingSubscriptions && !f.store.isRefreshing }
        f.store.loadAvailableAccounts()
        await f.until { f.store.hasLoadedAccounts }
        var currencyConfig = f.store.configuration
        currencyConfig.actualCostCurrency = "¥"
        currencyConfig.subscriptionCostCurrency = "¥"
        try await f.store.save(currencyConfig, key: "fake-secret")
        await f.until { !f.store.showsQuotaLoading }
        let version = AppVersion.display(in: ["Sub2BarVersion": "0.1.0-beta.1", "CFBundleVersion": "12.2.0"])
        let panel = PopoverView(store: f.store, openSettings: {}, version: version).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: panel)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 864)
        XCTAssertLessThan(image.height, 1320, "One account should shrink below the previous maximum")
        XCTAssertGreaterThan(image.height, 800, "Header, summary, account and footer remain visible")
        for text in ["额度刷新 00:05", "额度刷新 00:00", "额度刷新 00:59", "待配置"] {
            let statusRenderer = ImageRenderer(content: QuotaRefreshStatus(text: text))
            statusRenderer.scale = 2
            let statusImage = try XCTUnwrap(statusRenderer.cgImage)
            XCTAssertEqual(statusImage.width, 248, "Countdown must retain its width across refresh boundaries")
            XCTAssertEqual(statusImage.height, 40)
        }
        for loading in [false, true] {
            let button = QuotaRefreshButton(isLoading: loading, isEnabled: true, action: {})
            let buttonRenderer = ImageRenderer(content: button)
            buttonRenderer.scale = 2
            let buttonImage = try XCTUnwrap(buttonRenderer.cgImage)
            XCTAssertEqual(buttonImage.width, 64, "Loading and reload must occupy the same slot")
            XCTAssertEqual(buttonImage.height, 64)
        }
        // Keep related collapsed-card and panel render coverage together.
        let original = try XCTUnwrap(f.store.snapshots.first)
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let usage = UsageInfo(
            fiveHour: UsageWindow(utilization: 20, resetsAt: formatter.string(from: now.addingTimeInterval(2 * 3_600 + 15 * 60 + 30))),
            sevenDay: UsageWindow(utilization: 40, resetsAt: formatter.string(from: now.addingTimeInterval(3 * 86_400 + 2 * 3_600 + 30))))
        let snapshot = AccountSnapshot(account: original.account, usage: usage,
                                       statisticsUsage: original.statisticsUsage)
        let requestCount = f.backend.requests.count
        for scheme in [ColorScheme.light, .dark] {
            for overview in [f.store.accountOverview,
                             PinnedAccountOverview(ids: Array(1...1000), snapshots: [], failedIDs: [1]) ] {
                let summary = AccountListSummary(overview: overview)
                    .frame(width: 396).environment(\.colorScheme, scheme)
                let summaryRenderer = ImageRenderer(content: summary)
                summaryRenderer.scale = 2
                let summaryImage = try XCTUnwrap(summaryRenderer.cgImage)
                XCTAssertEqual(summaryImage.width, 792)
                XCTAssertLessThan(summaryImage.height, 100, "Summary stays lightweight even with unavailable data")
            }
            for label in [version, "0.1.0", "开发版"] {
                let badge = VersionBadge(version: label).environment(\.colorScheme, scheme)
                let badgeRenderer = ImageRenderer(content: badge)
                badgeRenderer.scale = 2
                let badgeImage = try XCTUnwrap(badgeRenderer.cgImage)
                XCTAssertEqual(badgeImage.height, 36, "Version badge should stay compact")
                XCTAssertGreaterThan(badgeImage.width, 40)
                XCTAssertLessThan(badgeImage.width, 200, "Full beta version must fit beside the connection status")
            }
            let themedPanel = PopoverView(store: f.store, openSettings: {}, version: version)
                .environment(\.colorScheme, scheme)
            let panelRenderer = ImageRenderer(content: themedPanel)
            panelRenderer.scale = 2
            let panelImage = try XCTUnwrap(panelRenderer.cgImage)
            XCTAssertEqual(panelImage.width, 864)
            XCTAssertLessThan(panelImage.height, 1320)
            XCTAssertGreaterThan(panelImage.height, 800)
            let icons = HStack(spacing: 20) {
                ForEach(["openai", "anthropic", "gemini", "antigravity", "unknown"], id: \.self) { platform in
                    VStack(spacing: 12) {
                        ProviderIcon(platform: platform).scaleEffect(2).frame(width: 40, height: 40)
                        Text(platform).font(.system(size: 10))
                    }
                }
            }.padding(20).background(NeutralPanelBackground()).environment(\.colorScheme, scheme)
            let iconsRenderer = ImageRenderer(content: icons)
            iconsRenderer.scale = 2
            let iconsImage = try XCTUnwrap(iconsRenderer.cgImage)
            let card = AccountCard(snapshot: snapshot, stale: false, isPanelVisible: true, todayCost: 12.34,
                                   subscription: f.store.subscriptions[1], subscriptionCycle: f.store.subscriptionCycle(for: 1),
                                   subscriptionSample: f.store.subscriptionSample(for: 1),
                                   actualCostCurrency: f.store.configuration.actualCostCurrency,
                                   subscriptionCostCurrency: f.store.configuration.subscriptionCostCurrency)
                .frame(width: 396).padding(18).background(NeutralPanelBackground())
                .environment(\.isMenuPanelSurface, true).environment(\.colorScheme, scheme)
            let cardRenderer = ImageRenderer(content: card)
            cardRenderer.scale = 2
            let cardImage = try XCTUnwrap(cardRenderer.cgImage)
            XCTAssertEqual(cardImage.width, 864)
            XCTAssertGreaterThan(cardImage.height, 200)
            XCTAssertLessThan(cardImage.height, 500, "Subscription metrics share the compact usage-row hierarchy")
            let expandedCard = AccountCard(snapshot: snapshot, stale: false, isPanelVisible: true, todayCost: 12.34,
                subscription: f.store.subscriptions[1], subscriptionCycle: f.store.subscriptionCycle(for: 1),
                subscriptionSample: f.store.subscriptionSample(for: 1), actualCostCurrency: "¥", subscriptionCostCurrency: "¥",
                expanded: true)
                .frame(width: 396).padding(18).background(NeutralPanelBackground())
                .environment(\.isMenuPanelSurface, true).environment(\.colorScheme, scheme)
            let expandedRenderer = ImageRenderer(content: expandedCard)
            expandedRenderer.scale = 2
            let expandedImage = try XCTUnwrap(expandedRenderer.cgImage)
            XCTAssertGreaterThan(expandedImage.height, cardImage.height + 200, "Details grow the card instead of scrolling inside it")
            XCTAssertEqual(expandedImage.width, cardImage.width)
            if let output = ProcessInfo.processInfo.environment["SUB2BAR_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let panelData = try XCTUnwrap(NSBitmapImageRep(cgImage: panelImage).representation(using: .png, properties: [:]))
                try panelData.write(to: directory.appendingPathComponent(scheme == .light ? "version-panel-light.png" : "version-panel-dark.png"))
                // Hosting in an offscreen AppKit window realizes the lazy list;
                // ImageRenderer alone omits its account cards.
                let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 432, height: 660),
                                             styleMask: .borderless, backing: .buffered, defer: false)
                previewWindow.isReleasedWhenClosed = false
                var reportedHeights: [CGFloat] = []
                let adaptivePanel = PopoverView(store: f.store, openSettings: {}, version: version,
                    onHeightChange: { height in
                        reportedHeights.append(height)
                        DispatchQueue.main.async {
                            previewWindow.setContentSize(NSSize(width: PanelSizing.width, height: height))
                        }
                    }).environment(\.colorScheme, scheme)
                let previewHost = NSHostingView(rootView: adaptivePanel)
                previewWindow.contentView = previewHost
                previewHost.frame = NSRect(x: 0, y: 0, width: 432, height: 660)
                previewHost.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                previewHost.layoutSubtreeIfNeeded()
                XCTAssertLessThan(previewHost.bounds.height, PanelSizing.initialHeight)
                XCTAssertEqual(previewHost.bounds.height, try XCTUnwrap(reportedHeights.last), accuracy: 1)
                let resizeCount = reportedHeights.count
                // An unrelated state update must not cause repeated resizing.
                f.store.search = "unused while filters are hidden"
                try await Task.sleep(for: .milliseconds(100))
                previewHost.layoutSubtreeIfNeeded()
                XCTAssertEqual(reportedHeights.count, resizeCount)
                f.store.search = ""
                let previewBitmap = try XCTUnwrap(previewHost.bitmapImageRepForCachingDisplay(in: previewHost.bounds))
                previewHost.cacheDisplay(in: previewHost.bounds, to: previewBitmap)
                let previewData = try XCTUnwrap(previewBitmap.representation(using: .png, properties: [:]))
                try previewData.write(to: directory.appendingPathComponent(scheme == .light ? "account-overview-light.png" : "account-overview-dark.png"))
                previewWindow.close()
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cardImage).representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent(scheme == .light ? "countdown-light.png" : "countdown-dark.png"))
                let expandedData = try XCTUnwrap(NSBitmapImageRep(cgImage: expandedImage).representation(using: .png, properties: [:]))
                try expandedData.write(to: directory.appendingPathComponent(scheme == .light ? "expanded-card-light.png" : "expanded-card-dark.png"))
                let iconData = try XCTUnwrap(NSBitmapImageRep(cgImage: iconsImage).representation(using: .png, properties: [:]))
                try iconData.write(to: directory.appendingPathComponent(scheme == .light ? "providers-light.png" : "providers-dark.png"))
            }
        }
        XCTAssertEqual(f.backend.requests.count, requestCount, "Rendering countdowns must not request fresh usage")
        if let output = ProcessInfo.processInfo.environment["SUB2BAR_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("panel-light.png"))
            let window = WindowFactory.settings()
            let host = NSHostingView(rootView: SettingsView(store: f.store).environment(\.colorScheme, .light))
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let settingsData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try settingsData.write(to: directory.appendingPathComponent("settings-light.png"))
            let refreshHost = NSHostingView(rootView: SettingsView(store: f.store, page: .refresh).environment(\.colorScheme, .light))
            window.contentView = refreshHost
            refreshHost.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
            refreshHost.layoutSubtreeIfNeeded()
            let refreshBitmap = try XCTUnwrap(refreshHost.bitmapImageRepForCachingDisplay(in: refreshHost.bounds))
            refreshHost.cacheDisplay(in: refreshHost.bounds, to: refreshBitmap)
            let refreshData = try XCTUnwrap(refreshBitmap.representation(using: .png, properties: [:]))
            try refreshData.write(to: directory.appendingPathComponent("settings-refresh-light.png"))
            for scheme in [ColorScheme.light, .dark] {
                for page in [SettingsPage.accounts, .statistics] {
                    let pageHost = NSHostingView(rootView: SettingsView(store: f.store, page: page).environment(\.colorScheme, scheme))
                    window.contentView = pageHost
                    pageHost.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
                    pageHost.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    pageHost.layoutSubtreeIfNeeded()
                    let pageBitmap = try XCTUnwrap(pageHost.bitmapImageRepForCachingDisplay(in: pageHost.bounds))
                    pageHost.cacheDisplay(in: pageHost.bounds, to: pageBitmap)
                    let pageData = try XCTUnwrap(pageBitmap.representation(using: .png, properties: [:]))
                    try pageData.write(to: directory.appendingPathComponent("settings-\(page == .accounts ? "accounts" : "statistics")-\(scheme == .light ? "light" : "dark").png"))
                }
                let editor = SubscriptionEditor(store: f.store, account: subscriptionAccount)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
                // TextField and Picker wrap AppKit controls; ImageRenderer
                // draws unsupported-control placeholders instead of those views.
                let editorHost = NSHostingView(rootView: editor)
                window.contentView = editorHost
                editorHost.frame = NSRect(x: 0, y: 0, width: 430, height: 360)
                editorHost.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                editorHost.layoutSubtreeIfNeeded()
                let editorBitmap = try XCTUnwrap(editorHost.bitmapImageRepForCachingDisplay(in: editorHost.bounds))
                editorHost.cacheDisplay(in: editorHost.bounds, to: editorBitmap)
                let editorData = try XCTUnwrap(editorBitmap.representation(using: .png, properties: [:]))
                try editorData.write(to: directory.appendingPathComponent("subscription-editor-\(scheme == .light ? "light" : "dark").png"))
            }
        }
        f.store.setPanelVisible(false)
        var pageHeights: [Int] = []
        for count in [2, 6] {
            let many = try StoreFixture(ids: Array(1...count)); defer { many.cleanup() }
            many.backend.directoryIDs = Array(1...count)
            await many.open()
            await many.until { !many.store.showsQuotaLoading }
            let manyRenderer = ImageRenderer(content: PopoverView(store: many.store, openSettings: {}))
            let manyImage = try XCTUnwrap(manyRenderer.cgImage)
            XCTAssertLessThan(manyImage.height, 660, "Multiple pins display a single page, not a tall list")
            pageHeights.append(manyImage.height)
            let calls = many.backend.requests.count
            many.store.selectAdjacentPinned(1)
            let nextRenderer = ImageRenderer(content: PopoverView(store: many.store, openSettings: {}).environment(\.colorScheme, .light))
            nextRenderer.scale = 2
            let nextImage = try XCTUnwrap(nextRenderer.cgImage)
            XCTAssertEqual(Double(nextImage.height) / 2, Double(manyImage.height), accuracy: 1,
                           "Paging identical cards preserves height within pixel rounding")
            XCTAssertEqual(many.backend.requests.count, calls, "Paging must not request extra data")
            if count == 2, let output = ProcessInfo.processInfo.environment["SUB2BAR_RENDER_DIR"] {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: nextImage).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("account-switching.png"))
                many.store.loadAvailableAccountsIfNeeded()
                await many.until { many.store.hasLoadedAccounts }
                many.store.movePinned(2, by: -1)
                let orderWindow = WindowFactory.settings()
                let orderHost = NSHostingView(rootView: SettingsView(store: many.store, page: .accounts).environment(\.colorScheme, .light))
                orderWindow.contentView = orderHost
                orderHost.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
                orderHost.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let bitmap = try XCTUnwrap(orderHost.bitmapImageRepForCachingDisplay(in: orderHost.bounds))
                orderHost.cacheDisplay(in: orderHost.bounds, to: bitmap)
                let orderData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try orderData.write(to: URL(fileURLWithPath: output).appendingPathComponent("account-order.png"))
                orderWindow.close()
            }
            many.store.setPanelVisible(false)
        }
        XCTAssertEqual(pageHeights[0], pageHeights[1], "More pins must not increase the page height")
    }
}
