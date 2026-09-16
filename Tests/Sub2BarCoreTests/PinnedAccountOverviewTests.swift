import XCTest
@testable import Sub2BarCore

final class PinnedAccountOverviewTests: XCTestCase {
    private func snapshot(_ id: Int, status: String = "active", percent: Double = 20,
                          fiveHour: Double = 20, usageError: String? = nil) throws -> AccountSnapshot {
        let data = Data("{\"id\":\(id),\"name\":\"Account \(id)\",\"platform\":\"openai\",\"status\":\"\(status)\"}".utf8)
        let account = try makeDecoder().decode(Account.self, from: data)
        return AccountSnapshot(account: account, usage: UsageInfo(fiveHour: UsageWindow(utilization: fiveHour),
                                                                sevenDay: UsageWindow(utilization: percent)), usageError: usageError)
    }

    func testAllAvailableHidesRedundantCounts() throws {
        let overview = PinnedAccountOverview(ids: [1, 2], snapshots: try [snapshot(1), snapshot(2)], failedIDs: [])
        XCTAssertEqual(overview.total, 2)
        XCTAssertEqual(overview.available, 2)
        XCTAssertEqual(overview.attention, 0)
        XCTAssertEqual(overview.statusText, "")
    }

    func testNearQuotaLimitOnlyAddsAttention() throws {
        let overview = PinnedAccountOverview(ids: [1], snapshots: try [snapshot(1, percent: 98)], failedIDs: [])
        XCTAssertEqual(overview.statusText, "")
        XCTAssertEqual(overview.attention, 1)
        XCTAssertEqual(overview.available, 1)
    }

    func testKnownUnavailableShowsFractionAndDoesNotDoubleCountWarnings() throws {
        let overview = PinnedAccountOverview(ids: [1, 2, 3], snapshots: try [snapshot(1), snapshot(2), snapshot(3, status: "disabled", percent: 98, usageError: "额度读取失败")], failedIDs: [])
        XCTAssertEqual(overview.statusText, "可调度 2/3")
        XCTAssertEqual(overview.attention, 1)
    }

    func testFailedCachedAccountDoesNotCountAsAvailableOrDuplicateWarning() throws {
        let overview = PinnedAccountOverview(ids: [1], snapshots: try [snapshot(1, percent: 98)], failedIDs: [1])
        XCTAssertEqual(overview.statusText, "读取失败 1")
        XCTAssertEqual(overview.attention, 0)
        XCTAssertEqual(overview.available, 0)
    }

    func testMissingAndUnknownAreNotPresentedAsZeroAvailability() throws {
        let overview = PinnedAccountOverview(ids: [1, 2, 3], snapshots: try [snapshot(1, status: "future-status")], failedIDs: [2])
        XCTAssertEqual(overview.statusText, "读取失败 1 · 待载入 1 · 状态未知 1")
        XCTAssertEqual(overview.attention, 0)
        XCTAssertEqual(overview.unknown, 1)
        XCTAssertEqual(overview.pending, 1)
    }

    func testFiveHourQuotaWarningMatchesCard() throws {
        let overview = PinnedAccountOverview(ids: [1], snapshots: try [snapshot(1, fiveHour: 95)], failedIDs: [])
        XCTAssertEqual(overview.attention, 1)
    }

    func testOnlyUniquePinsCountAndGlobalFailureInvalidatesCachedStatus() throws {
        let snapshots = try [snapshot(1), snapshot(99, percent: 98)]
        let overview = PinnedAccountOverview(ids: [1, 1], snapshots: snapshots, failedIDs: [99])
        XCTAssertEqual(overview.total, 1)
        XCTAssertEqual(overview.available, 1)
        XCTAssertEqual(overview.attention, 0)
        XCTAssertEqual(overview.statusText, "")
        let stale = PinnedAccountOverview(ids: [1], snapshots: snapshots, failedIDs: [], stale: true)
        XCTAssertEqual(stale.statusText, "读取失败 1")
        XCTAssertEqual(stale.available, 0)
    }
}
