import XCTest
@testable import Sub2Bar

final class PanelSizingTests: XCTestCase {
    func testShortContentShrinksAndExpandedContentGrowsWithoutScrolling() {
        let small: [PanelSection: CGFloat] = [.header: 66, .footer: 52, .dashboard: 200, .accounts: 220]
        XCTAssertEqual(PanelSizing.height(measurements: small, hasDashboard: true), 562)
        var tall = small; tall[.accounts] = 900
        XCTAssertEqual(PanelSizing.height(measurements: tall, hasDashboard: true), 1242)
    }

    func testOnlyVisiblePageMeasurementsDetermineHeight() {
        let page: [PanelSection: CGFloat] = [.header: 66, .footer: 52, .dashboard: 200, .accounts: 180]
        XCTAssertEqual(PanelSizing.height(measurements: page, hasDashboard: true), 522)
    }

    func testSetupUsesCompactHeightAndIncompleteMeasurementUsesSafeMaximum() {
        XCTAssertEqual(PanelSizing.height(measurements: [:], hasDashboard: false), 360)
        XCTAssertEqual(PanelSizing.height(measurements: [:], hasDashboard: true), 660)
        XCTAssertEqual(PanelSizing.height(measurements: [.header: .nan], hasDashboard: true), 660)
    }
}
