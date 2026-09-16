import AppKit
import SwiftUI
import XCTest
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
        let panel = PopoverView(store: f.store, openSettings: {}).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: panel)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 864)
        XCTAssertEqual(image.height, 1320)
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
        }
    }
}
