import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class PinnedNavigationTests: XCTestCase {
    func testOnlyPinsCanBeSelectedAndNavigationWrapsInOrder() throws {
        let f = try StoreFixture(ids: [7, 2, 9]); defer { f.cleanup() }
        XCTAssertEqual(f.store.selectedPinnedID, 7)
        f.store.selectAdjacentPinned(1)
        XCTAssertEqual(f.store.selectedPinnedID, 2)
        f.store.selectAdjacentPinned(-1)
        XCTAssertEqual(f.store.selectedPinnedID, 7)
        f.store.selectAdjacentPinned(-1)
        XCTAssertEqual(f.store.selectedPinnedID, 9)
        f.store.selectPinned(999)
        XCTAssertEqual(f.store.selectedPinnedID, 9)
        XCTAssertTrue(f.backend.requests.isEmpty)
    }

    func testMovingPinsPersistsOrderWithoutRefetchingOrChangingSelectedID() async throws {
        let f = try StoreFixture(ids: [7, 2, 9]); defer { f.cleanup() }
        await f.open()
        let count = f.backend.requests.count
        let quotaTime = f.store.nextRefreshAt
        let total = f.store.estimatedTotal
        f.store.selectPinned(2)
        f.store.movePinned(2, by: -1)
        XCTAssertEqual(f.store.pinnedIDs, [2, 7, 9])
        XCTAssertEqual(f.store.snapshots.map(\.id), [2, 7, 9])
        XCTAssertEqual(f.store.selectedPinnedID, 2)
        XCTAssertEqual(f.store.selectedPinnedIndex, 0)
        XCTAssertEqual(f.store.nextRefreshAt, quotaTime)
        XCTAssertEqual(f.store.estimatedTotal, total)
        XCTAssertEqual(f.backend.requests.count, count)
        let restored = AppStore(defaults: f.defaults, credentials: CredentialSession(storage: f.vault), automaticallySchedule: false)
        XCTAssertEqual(restored.pinnedIDs, [2, 7, 9])
        XCTAssertEqual(restored.selectedPinnedID, 2)
    }

    func testUnpinSelectedChoosesNeighborAndEmptyPinsHaveNoSelection() throws {
        let f = try StoreFixture(ids: [7, 2, 9]); defer { f.cleanup() }
        f.store.selectPinned(2)
        f.store.setPinned(false, id: 2)
        XCTAssertEqual(f.store.selectedPinnedID, 9)
        f.store.setPinned(false, id: 9)
        XCTAssertEqual(f.store.selectedPinnedID, 7)
        f.store.setPinned(false, id: 7)
        XCTAssertNil(f.store.selectedPinnedID)
        f.store.selectAdjacentPinned(1)
        XCTAssertNil(f.store.selectedPinnedID)
        f.store.setPinned(true, id: 4)
        XCTAssertEqual(f.store.selectedPinnedID, 4)
    }

    func testDirectoryShowsPinnedOrderFirstWithoutMutatingCachedRows() async throws {
        let f = try StoreFixture(ids: [9, 2]); defer { f.cleanup() }
        f.backend.directoryIDs = [1, 2, 9]
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { f.store.hasLoadedAccounts }
        XCTAssertEqual(f.store.orderedAvailableAccounts.map(\.id), [9, 2, 1])
        let cacheTime = f.store.accountsUpdatedAt
        f.store.movePinned(2, by: -1)
        XCTAssertEqual(f.store.orderedAvailableAccounts.map(\.id), [2, 9, 1])
        XCTAssertEqual(f.store.availableAccounts.map(\.id), [1, 2, 9])
        XCTAssertEqual(f.store.accountsUpdatedAt, cacheTime)
        XCTAssertEqual(f.backend.directoryCount, 1)
    }

    func testSelectionDoesNotRestrictSubscriptionTotalsOrRequestNewUsage() async throws {
        let f = try StoreFixture(ids: [1, 2]); defer { f.cleanup() }
        await f.open()
        for snapshot in f.store.snapshots {
            try f.store.saveSubscription(AccountSubscription(monthlyPrice: 20, renewalDay: 12), for: snapshot.account)
        }
        await f.until { !f.store.isRefreshingSubscriptions }
        let count = f.backend.requests.count
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 200)
        XCTAssertEqual(f.store.totalSubscriptionCost, 40)
        f.store.selectAdjacentPinned(1)
        f.store.movePinned(2, by: -1)
        XCTAssertEqual(f.store.selectedPinnedID, 2)
        XCTAssertEqual(f.store.totalSubscriptionActualCost, 200)
        XCTAssertEqual(f.store.totalSubscriptionCost, 40)
        XCTAssertEqual(f.backend.requests.count, count)
    }
}
