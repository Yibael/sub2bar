import AppKit
import XCTest
import SwiftUI
@testable import Sub2Bar

@MainActor
final class WindowChromeTests: XCTestCase {
    func testPanelSurfacesAddNoFillInEitherAppearance() {
        XCTAssertEqual(SurfaceStyle.fill(panel: true, reduceTransparency: false, dark: false), .clear)
        XCTAssertEqual(SurfaceStyle.fill(panel: true, reduceTransparency: false, dark: true), .clear)
    }

    func testPanelSurfacesRespectReducedTransparencyAndKeepSettingsStyle() {
        XCTAssertEqual(SurfaceStyle.fill(panel: true, reduceTransparency: true, dark: false), Color(nsColor: .controlBackgroundColor))
        XCTAssertEqual(SurfaceStyle.fill(panel: false, reduceTransparency: false, dark: false), Color.white.opacity(0.18))
        XCTAssertEqual(SurfaceStyle.fill(panel: false, reduceTransparency: false, dark: true), Color.white.opacity(0.025))
    }

    func testSettingsUsesPaintedInteractiveTitlebar() async {
        _ = NSApplication.shared
        let window = WindowFactory.settings()
        assertNativeChrome(window)
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)
    }

    func testSettingsTrafficLightsAreHitTestable() async throws {
        _ = NSApplication.shared
        let window = WindowFactory.settings()
        let frame = try XCTUnwrap(window.contentView?.superview)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: frame)
            let hit = try XCTUnwrap(frame.hitTest(point))
            XCTAssertTrue(hit === button || hit.isDescendant(of: button))
        }
    }

    func testSettingsHasNativeTitlebarAboveContent() async throws {
        _ = NSApplication.shared
        let window = WindowFactory.settings()
        let content = try XCTUnwrap(window.contentView)
        let frame = try XCTUnwrap(content.superview)
        XCTAssertGreaterThan(frame.bounds.height, content.frame.height)
        let point = NSPoint(x: frame.bounds.midX, y: content.frame.maxY + (frame.bounds.maxY - content.frame.maxY) / 2)
        XCTAssertNotNil(frame.hitTest(point))
    }

    private func assertNativeChrome(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.isOpaque, file: file, line: line)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 1, file: file, line: line)
        XCTAssertFalse(window.titlebarAppearsTransparent, file: file, line: line)
        XCTAssertFalse(window.ignoresMouseEvents, file: file, line: line)
        XCTAssertTrue(window.isMovable, file: file, line: line)
        XCTAssertTrue(window.canBecomeKey, file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.titled), file: file, line: line)
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.isEnabled == true, file: file, line: line)
    }
}
