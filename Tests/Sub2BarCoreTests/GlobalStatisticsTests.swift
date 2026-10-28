import XCTest
@testable import Sub2BarCore

private final class GlobalStatisticsProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GlobalStatisticsTests: XCTestCase {
    private func client() -> APIClient {
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [GlobalStatisticsProtocol.self]
        return APIClient(configuration: Configuration(serverURL: "https://example.invalid"), key: "test-key",
                         session: URLSession(configuration: session))
    }
    private var period: StatisticsPeriod { StatisticsPeriod(at: parseAPIDate("2026-10-28T12:00:00Z")!, timeZoneID: "Asia/Shanghai")! }
    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }
    override func tearDown() { GlobalStatisticsProtocol.handler = nil; super.tearDown() }

    func testCalendarWindowIncludesTodayAndPrevious29DaysAcrossDSTAndLeapMonth() throws {
        for (date, zone, today, start) in [
            ("2026-10-28T12:00:00Z", "Asia/Shanghai", "2026-10-28", "2026-09-29"),
            ("2026-03-10T12:00:00Z", "America/New_York", "2026-03-10", "2026-02-09"),
            ("2024-03-01T01:00:00Z", "Asia/Shanghai", "2024-03-01", "2024-02-01"),
            ("2026-01-01T01:00:00Z", "America/Los_Angeles", "2025-12-31", "2025-12-02")
        ] {
            let value = try XCTUnwrap(StatisticsPeriod(at: parseAPIDate(date)!, timeZoneID: zone))
            XCTAssertEqual(value.today, today); XCTAssertEqual(value.thirtyDaysStart, start)
        }
        XCTAssertNil(StatisticsPeriod(at: Date(), timeZoneID: "invalid"))
    }

    func testGlobalQueriesOmitAccountFilterAndExcludeAllAdminsFromBothPrices() async throws {
        let lock = NSLock(); var requests: [[String: String]] = []
        GlobalStatisticsProtocol.handler = { request in
            lock.withLock {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
                let query = self.query(request); requests.append(query)
                if request.url!.path.hasSuffix("/users") {
                    let id = query["page"] == "1" ? 9 : 42
                    return (200, "{\"code\":0,\"data\":{\"items\":[{\"id\":\(id),\"role\":\"admin\"}],\"total\":2}}")
                }
                XCTAssertEqual(request.url!.path, "/api/v1/admin/usage/stats")
                XCTAssertEqual(query["timezone"], "Asia/Shanghai")
                XCTAssertEqual(query["end_date"], "2026-10-28")
                XCTAssertEqual(query["nocache"], "true")
                let isAdmin = query["user_id"] != nil
                return (200, isAdmin ? #"{"code":0,"data":{"total_cost":10.1,"total_actual_cost":0.1}}"# :
                    #"{"code":0,"data":{"total_cost":100.3,"total_actual_cost":0.3}}"#)
            }
        }
        let result = try await client().loadGlobalStatistics(period: period, includeAdmin: false, accountIDs: [7, 7, -1])
        XCTAssertEqual(result.today.totalCost, Decimal(string: "80.1"))
        XCTAssertEqual(result.today.totalActualCost, Decimal(string: "0.1"))
        XCTAssertEqual(result.thirtyDays.totalActualCost, Decimal(string: "0.1"))
        XCTAssertEqual(result.accounts[7], result.today)
        XCTAssertEqual(result.accounts.count, 1)
        XCTAssertEqual(requests.filter { $0["role"] == "admin" }.count, 2)
        XCTAssertEqual(requests.filter { $0["start_date"] != nil && $0["account_id"] == nil }.count, 6)
        XCTAssertEqual(requests.filter { $0["account_id"] == "7" }.count, 3)
        XCTAssertTrue(requests.contains { $0["start_date"] == "2026-09-29" })
    }

    func testNoPinsStillQueriesGlobalAndMissingFieldsStayIndependent() async throws {
        GlobalStatisticsProtocol.handler = { request in
            let query = self.query(request)
            XCTAssertNil(query["account_id"]); XCTAssertNil(query["user_id"])
            XCTAssertEqual(request.url!.path, "/api/v1/admin/usage/stats")
            return (200, #"{"code":0,"data":{"total_cost":0}}"#)
        }
        let result = try await client().loadGlobalStatistics(period: period, includeAdmin: true, accountIDs: [])
        XCTAssertEqual(result.today.totalCost, 0); XCTAssertNil(result.today.totalActualCost)
        XCTAssertTrue(result.accounts.isEmpty)
    }

    func testFailedAdminDiscoveryNeverFallsBackToIncludedTotals() async throws {
        GlobalStatisticsProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/users"))
            return (200, #"{"code":0,"data":{"items":[],"total":2}}"#)
        }
        do { _ = try await client().loadGlobalStatistics(period: period, includeAdmin: false, accountIDs: [1]); XCTFail() }
        catch { XCTAssertEqual(error as? SubscriptionError, .invalidAdminList) }
    }

    func testNegativeSubtractionFailsOnlyAffectedFieldAndAuthenticationPropagates() async throws {
        GlobalStatisticsProtocol.handler = { request in
            if request.url!.path.hasSuffix("/users") {
                return (200, #"{"code":0,"data":{"items":[{"id":9,"role":"admin"}],"total":1}}"#)
            }
            return (200, self.query(request)["user_id"] == nil ?
                #"{"code":0,"data":{"total_cost":1,"total_actual_cost":10}}"# :
                #"{"code":0,"data":{"total_cost":2,"total_actual_cost":3}}"#)
        }
        let result = try await client().loadGlobalStatistics(period: period, includeAdmin: false, accountIDs: [])
        XCTAssertNil(result.today.totalCost); XCTAssertEqual(result.today.totalActualCost, 7)
        GlobalStatisticsProtocol.handler = { _ in (401, "private error") }
        do { _ = try await client().loadGlobalStatistics(period: period, includeAdmin: true, accountIDs: []); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .http(401)) }
    }

    func testConcurrencyUsesUniqueAccountsAndRejectsDisabledMissingOrInvalidMonitoring() async throws {
        GlobalStatisticsProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/api/v1/admin/ops/concurrency")
            XCTAssertNil(request.url!.query)
            return (200, #"{"code":0,"data":{"enabled":true,"account":{"1":{"current_in_use":2,"max_capacity":5},"7":{"current_in_use":3,"max_capacity":10}},"group":{"1":{"current_in_use":99,"max_capacity":99}}}}"#)
        }
        let value = try await client().loadGlobalConcurrency()
        XCTAssertEqual(value.count, 5); XCTAssertEqual(value.limit, 15)
        for payload in [#"{"enabled":false,"account":{}}"#, #"{"enabled":true}"#,
                        #"{"enabled":true,"account":{"1":{"current_in_use":-1,"max_capacity":5}}}"#] {
            GlobalStatisticsProtocol.handler = { _ in (200, "{\"code\":0,\"data\":\(payload)}") }
            do { _ = try await client().loadGlobalConcurrency(); XCTFail("Must not display unavailable monitoring as zero") } catch {}
        }
    }
}
