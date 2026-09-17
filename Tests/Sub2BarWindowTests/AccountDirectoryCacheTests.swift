import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class AccountDirectoryCacheTests: XCTestCase {
    func testFirstEntryLoadsAndReentryWithinMinuteUsesMemoryCache() async throws {
        let f = try StoreFixture(ids: []); defer { f.cleanup() }
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { f.store.hasLoadedAccounts && !f.store.isLoadingAccounts }
        XCTAssertEqual(f.backend.directoryCount, 1)
        XCTAssertTrue(f.store.hasFreshAccountDirectory)
        f.date = f.date.addingTimeInterval(59)
        f.store.loadAvailableAccountsIfNeeded()
        XCTAssertEqual(f.backend.directoryCount, 1)
        XCTAssertEqual(f.backend.batchCount, 0)
        XCTAssertEqual(f.backend.todayCount, 0)
        XCTAssertEqual(f.backend.statsCount, 0)
    }

    func testExpiredEntryKeepsOldRowsUntilBackgroundRefreshCompletes() async throws {
        let f = try StoreFixture(ids: []); defer { f.cleanup() }
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { f.store.hasLoadedAccounts }
        f.date = f.date.addingTimeInterval(60)
        f.backend.directoryIDs = [2]; f.backend.delayAccounts = 0.1
        XCTAssertFalse(f.store.hasFreshAccountDirectory)
        XCTAssertEqual(f.backend.directoryCount, 1, "Expiry itself does not start a timer or request")
        f.store.loadAvailableAccountsIfNeeded()
        XCTAssertTrue(f.store.isLoadingAccounts)
        XCTAssertEqual(f.store.availableAccounts.map(\.id), [1])
        await f.until { !f.store.isLoadingAccounts }
        XCTAssertEqual(f.store.availableAccounts.map(\.id), [2])
        XCTAssertEqual(f.store.accountsUpdatedAt, f.date)
        XCTAssertEqual(f.backend.directoryCount, 2)
    }

    func testManualRefreshBypassesTTLAndConcurrentEntriesAreCoalesced() async throws {
        let f = try StoreFixture(ids: []); defer { f.cleanup() }
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { f.store.hasLoadedAccounts }
        f.backend.delayAccounts = 0.1
        f.store.loadAvailableAccounts()
        for _ in 0..<10 { f.store.loadAvailableAccounts(); f.store.loadAvailableAccountsIfNeeded() }
        await f.until { !f.store.isLoadingAccounts }
        XCTAssertEqual(f.backend.directoryCount, 2)
    }

    func testEmptySuccessfulDirectoryIsCached() async throws {
        let f = try StoreFixture(ids: []); defer { f.cleanup() }
        f.backend.directoryIDs = []
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { f.store.hasLoadedAccounts }
        f.store.loadAvailableAccountsIfNeeded()
        XCTAssertTrue(f.store.availableAccounts.isEmpty)
        XCTAssertTrue(f.store.hasFreshAccountDirectory)
        XCTAssertEqual(f.backend.directoryCount, 1)
    }

    func testFailedRefreshPreservesRowsAndOriginalTimestamp() async throws {
        let f = try StoreFixture(ids: []); defer { f.cleanup() }
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { f.store.hasLoadedAccounts }
        let originalTime = f.store.accountsUpdatedAt
        f.date = f.date.addingTimeInterval(61); f.backend.error = 503
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { !f.store.isLoadingAccounts }
        XCTAssertEqual(f.store.availableAccounts.map(\.id), [1])
        XCTAssertEqual(f.store.accountsUpdatedAt, originalTime)
        XCTAssertNotNil(f.store.accountsError)
        XCTAssertFalse(f.store.hasFreshAccountDirectory)
        f.backend.error = 0
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { !f.store.isLoadingAccounts }
        XCTAssertNil(f.store.accountsError)
        XCTAssertTrue(f.store.hasFreshAccountDirectory)
    }

    func testAuthenticationFailureDoesNotLoopOnAppearance() async throws {
        let f = try StoreFixture(ids: []); defer { f.cleanup() }
        f.backend.error = 401
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { f.store.credentialError != nil }
        let count = f.backend.directoryCount
        for _ in 0..<5 { f.store.loadAvailableAccountsIfNeeded() }
        XCTAssertEqual(f.backend.directoryCount, count)
    }

    func testServerChangeDiscardsLateDirectoryAndKeyChangeClearsCache() async throws {
        let f = try StoreFixture(ids: []); defer { f.cleanup() }
        await f.store.prepareCredentials()
        f.backend.delayAccounts = 0.2
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { f.backend.directoryCount == 1 }
        let oldIdentity = f.store.accountDirectoryIdentity
        var config = f.store.configuration; config.serverURL = "https://other.example.invalid"
        try await f.store.save(config, key: "fake-secret")
        XCTAssertNotEqual(f.store.accountDirectoryIdentity, oldIdentity)
        XCTAssertFalse(f.store.hasLoadedAccounts)
        XCTAssertTrue(f.store.availableAccounts.isEmpty)
        f.backend.delayAccounts = 0; f.backend.directoryIDs = [9]
        f.store.loadAvailableAccountsIfNeeded()
        await f.until { f.store.hasLoadedAccounts }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(f.store.availableAccounts.map(\.id), [9])
        try await f.store.save(config, key: "new-secret")
        XCTAssertFalse(f.store.hasLoadedAccounts)
        XCTAssertNil(f.store.accountsUpdatedAt)
        XCTAssertTrue(f.store.availableAccounts.isEmpty)
    }
}
