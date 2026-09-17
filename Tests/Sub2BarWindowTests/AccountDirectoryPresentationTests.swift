import XCTest
import Sub2BarCore
@testable import Sub2Bar

final class AccountDirectoryPresentationTests: XCTestCase {
    private func accounts() throws -> [Account] {
        try makeDecoder().decode([Account].self, from: Data(#"[{"id":1,"name":"主账号","platform":"openai","type":"oauth"},{"id":2,"name":"Claude 2","platform":"anthropic","type":"apikey"},{"id":3,"name":"备用账号","platform":"openai","type":"oauth"},{"id":4,"name":"Claude 10","platform":"anthropic","type":"oauth"}]"#.utf8))
    }

    func testSectionsPreservePinnedSequenceAndSortOtherAccountsNaturally() throws {
        let source = try accounts()
        let result = AccountDirectoryPresentation(accounts: source, pinnedIDs: [3, 1], hasLoaded: true)
        XCTAssertEqual(result.pinned.map(\.id), [3, 1])
        XCTAssertEqual(result.others.map(\.id), [2, 4])
        XCTAssertEqual(source.map(\.id), [1, 2, 3, 4])
    }

    func testSearchAndOAuthFiltersApplyToBothSections() throws {
        let source = try accounts()
        let result = AccountDirectoryPresentation(accounts: source, pinnedIDs: [3, 1], hasLoaded: true,
            search: "  OPENAI  ", onlyOAuth: true)
        XCTAssertEqual(result.pinned.map(\.id), [3, 1])
        XCTAssertTrue(result.others.isEmpty)
        let id = AccountDirectoryPresentation(accounts: source, pinnedIDs: [3, 1], hasLoaded: true, search: "4")
        XCTAssertEqual(id.others.map(\.id), [4])
        let pinned = AccountDirectoryPresentation(accounts: source, pinnedIDs: [2, 1], hasLoaded: true,
            onlyPinned: true, onlyOAuth: true)
        XCTAssertEqual(pinned.pinned.map(\.id), [1])
        XCTAssertTrue(pinned.others.isEmpty)
    }

    func testMissingPinsOnlyAppearAfterLoadAndRemainRecoverableWithFilters() throws {
        let pending = AccountDirectoryPresentation(accounts: [], pinnedIDs: [7, 1], hasLoaded: false)
        XCTAssertTrue(pending.missingPinnedIDs.isEmpty)
        let loaded = AccountDirectoryPresentation(accounts: try accounts(), pinnedIDs: [7, 1, 9], hasLoaded: true,
            search: "no match", onlyOAuth: true)
        XCTAssertEqual(loaded.missingPinnedIDs, [7, 9])
        XCTAssertFalse(loaded.isEmpty)
    }
}
