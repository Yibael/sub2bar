import XCTest
import SwiftUI
import Sub2BarCore
@testable import Sub2Bar

final class ProviderIconTests: XCTestCase {
    func testKnownPlatformsAndUnknownFallback() {
        XCTAssertEqual(ProviderBrand(platform: "openai"), .openai)
        XCTAssertEqual(ProviderBrand(platform: "anthropic"), .anthropic)
        XCTAssertEqual(ProviderBrand(platform: "gemini"), .gemini)
        XCTAssertEqual(ProviderBrand(platform: "antigravity"), .antigravity)
        XCTAssertEqual(ProviderBrand(platform: " OpenAI\n"), .openai)
        XCTAssertNil(ProviderBrand(platform: "future-provider"))
        XCTAssertNil(ProviderBrand(platform: ""))
    }

    func testIconUsesPlatformNotNameOrAuthenticationType() throws {
        let account = try makeDecoder().decode(Account.self, from: Data(
            #"{"id":1,"name":"Claude account label","platform":"openai","type":"oauth"}"#.utf8))
        XCTAssertEqual(ProviderBrand(platform: account.platform), .openai)
        XCTAssertNil(ProviderBrand(platform: account.type ?? ""))
    }

    func testVectorPathsAreNonemptyAndStayInsideViewport() {
        for brand in ProviderBrand.allCases {
            XCTAssertFalse(brand.path.isEmpty)
            let bounds = brand.path.boundingRect
            XCTAssertGreaterThan(bounds.width, 15)
            XCTAssertGreaterThan(bounds.height, 15)
            XCTAssertGreaterThanOrEqual(bounds.minX, -0.01)
            XCTAssertGreaterThanOrEqual(bounds.minY, -0.01)
            XCTAssertLessThanOrEqual(bounds.maxX, 24.01)
            XCTAssertLessThanOrEqual(bounds.maxY, 24.01)
            let scaled = ProviderBrandShape(brand: brand).path(in: CGRect(x: 0, y: 0, width: 18, height: 18))
            XCTAssertLessThanOrEqual(scaled.boundingRect.maxX, 18.01)
            XCTAssertLessThanOrEqual(scaled.boundingRect.maxY, 18.01)
        }
    }
}
