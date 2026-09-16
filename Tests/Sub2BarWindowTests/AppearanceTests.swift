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
        await f.open()
        let version = AppVersion.display(in: ["Sub2BarVersion": "0.1.0-beta.1", "CFBundleVersion": "12.2.0"])
        let panel = PopoverView(store: f.store, openSettings: {}, version: version).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: panel)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 864)
        XCTAssertEqual(image.height, 1320)
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
        // Keep collapsed-card render coverage in this existing Metal test so
        // the hosted Intel workaround still excludes exactly two tests.
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
            XCTAssertEqual(panelImage.height, 1320)
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
            let card = AccountCard(snapshot: snapshot, stale: false, isPanelVisible: true)
                .frame(width: 396).padding(18).background(NeutralPanelBackground())
                .environment(\.isMenuPanelSurface, true).environment(\.colorScheme, scheme)
            let cardRenderer = ImageRenderer(content: card)
            cardRenderer.scale = 2
            let cardImage = try XCTUnwrap(cardRenderer.cgImage)
            XCTAssertEqual(cardImage.width, 864)
            XCTAssertGreaterThan(cardImage.height, 200)
            XCTAssertLessThan(cardImage.height, 400, "Collapsed card must not include expanded details")
            if let output = ProcessInfo.processInfo.environment["SUB2BAR_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let panelData = try XCTUnwrap(NSBitmapImageRep(cgImage: panelImage).representation(using: .png, properties: [:]))
                try panelData.write(to: directory.appendingPathComponent(scheme == .light ? "version-panel-light.png" : "version-panel-dark.png"))
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cardImage).representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent(scheme == .light ? "countdown-light.png" : "countdown-dark.png"))
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
        }
    }
}
