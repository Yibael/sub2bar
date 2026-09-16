import XCTest
@testable import Sub2BarCore

final class AppVersionTests: XCTestCase {
    func testDisplaysFullPrereleaseWithoutBuildNumber() {
        XCTAssertEqual(AppVersion.display(in: ["Sub2BarVersion": "0.1.0-beta.1",
                                              "CFBundleShortVersionString": "0.1.0",
                                              "CFBundleVersion": "12.2.0"]), "0.1.0-beta.1")
    }

    func testSupportsStableLegacyBundle() {
        XCTAssertEqual(AppVersion.display(in: ["CFBundleShortVersionString": "1.5.0",
                                              "CFBundleVersion": "10"]), "1.5.0")
    }

    func testUnpackagedBuildHasDevelopmentLabel() {
        XCTAssertEqual(AppVersion.display(in: nil), "开发版")
        XCTAssertEqual(AppVersion.display(in: ["CFBundleVersion": "12.2.0"]), "开发版")
        XCTAssertEqual(AppVersion.display(in: ["Sub2BarVersion": "", "CFBundleShortVersionString": "0.1.0"]), "0.1.0")
    }
}
