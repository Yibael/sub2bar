import XCTest
@testable import Sub2BarCore

private final class SubscriptionProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class SubscriptionAPITests: XCTestCase {
    private let date = parseAPIDate("2026-09-17T10:00:00Z")!
    override func tearDown() { SubscriptionProtocol.handler = nil; super.tearDown() }
    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SubscriptionProtocol.self]
        return APIClient(configuration: Configuration(serverURL: "https://example.invalid"), key: "test-key",
                         session: URLSession(configuration: config))
    }
    private func request(_ id: Int = 7) -> SubscriptionUsageRequest {
        SubscriptionUsageRequest(accountID: id, cycle: SubscriptionCycle(renewalDay: 12, at: date, timeZoneID: "Asia/Shanghai")!)
    }
    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }
    private func envelope(_ data: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["code": 0, "data": data]), as: UTF8.self)
    }

    func testIncludedAdminUsesOnlyActualCostAndExplicitCalendarDateFilters() async throws {
        var count = 0
        SubscriptionProtocol.handler = { request in
            count += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/admin/usage/stats")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
            XCTAssertEqual(self.query(request), ["account_id": "7", "start_date": "2026-09-12", "end_date": "2026-09-17", "timezone": "Asia/Shanghai", "nocache": "true"])
            return (200, #"{"code":0,"data":{"total_actual_cost":12.34,"total_cost":999,"cost":888}}"#)
        }
        let result = try await client().loadSubscriptionUsage([request()], includeAdmin: true, at: date)
        XCTAssertEqual(result.first?.actualCost, Decimal(string: "12.34"))
        XCTAssertNil(result.first?.error)
        XCTAssertEqual(count, 1)
    }

    func testExcludedAdminUsesAllAdminIDsAndNoAssumedUserOne() async throws {
        var userIDs: [String] = []
        SubscriptionProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let query = self.query(request)
            if request.url!.path.hasSuffix("/users") {
                XCTAssertEqual(query["role"], "admin")
                XCTAssertEqual(query["page_size"], "100")
                let id = query["page"] == "1" ? 9 : 42
                return (200, try self.envelope(["items": [["id": id, "role": "admin"]], "total": 2]))
            }
            XCTAssertEqual(request.url?.path, "/api/v1/admin/usage/stats")
            XCTAssertEqual(query["account_id"], "7")
            XCTAssertEqual(query["start_date"], "2026-09-12")
            XCTAssertEqual(query["end_date"], "2026-09-17")
            XCTAssertEqual(query["timezone"], "Asia/Shanghai")
            userIDs.append(query["user_id"] ?? "total")
            return (200, try self.envelope(["total_actual_cost": query["user_id"] == nil ? 100 : 15]))
        }
        let result = try await client().loadSubscriptionUsage([request()], includeAdmin: false, at: date)
        XCTAssertEqual(result.first?.actualCost, 70)
        XCTAssertEqual(userIDs, ["9", "42", "total"])
    }

    func testDecimalSubtractionPreservesCents() async throws {
        SubscriptionProtocol.handler = { request in
            if request.url!.path.hasSuffix("/users") {
                return (200, #"{"code":0,"data":{"items":[{"id":9,"role":"admin"}],"total":1}}"#)
            }
            return (200, self.query(request)["user_id"] == nil ? #"{"code":0,"data":{"total_actual_cost":0.3}}"# : #"{"code":0,"data":{"total_actual_cost":0.2}}"#)
        }
        let result = try await client().loadSubscriptionUsage([request()], includeAdmin: false, at: date)
        XCTAssertEqual(result.first?.actualCost, Decimal(string: "0.1"))
    }

    func testMissingActualCostIsNotReplacedWithStandardPriceOrZero() async throws {
        SubscriptionProtocol.handler = { _ in (200, #"{"code":0,"data":{"total_cost":123}}"#) }
        let result = try await client().loadSubscriptionUsage([request()], includeAdmin: true, at: date)
        XCTAssertNil(result.first?.actualCost)
        XCTAssertNotNil(result.first?.error)
    }

    func testIncompleteAdminListFailsClosedWithoutUnfilteredStatistics() async throws {
        for invalid in [#"{"items":[{"id":9,"role":"user"}],"total":1}"#,
                        #"{"items":[],"total":2}"#,
                        #"{"items":[{"id":9}],"total":1}"#] {
            var count = 0
            SubscriptionProtocol.handler = { request in
                count += 1
                XCTAssertTrue(request.url!.path.hasSuffix("/users"))
                return (200, "{\"code\":0,\"data\":\(invalid)}")
            }
            do { _ = try await client().loadSubscriptionUsage([request()], includeAdmin: false, at: date); XCTFail("Expected failure") }
            catch { XCTAssertEqual(count, 1) }
        }
    }

    func testFailedAccountDoesNotHideHealthyAccount() async throws {
        SubscriptionProtocol.handler = { request in
            (self.query(request)["account_id"] == "2" ? 503 : 200, #"{"code":0,"data":{"total_actual_cost":0}}"#)
        }
        let results = try await client().loadSubscriptionUsage([request(), request(2)], includeAdmin: true, at: date)
        XCTAssertEqual(results.map(\.request.accountID), [7, 2])
        XCTAssertEqual(results[0].actualCost, 0)
        XCTAssertNil(results[1].actualCost)
        XCTAssertEqual(results[1].error, "订阅消费读取失败")
    }

    func testNegativeOrInconsistentStatisticsAreNotReportedAsZero() async throws {
        for includeAdmin in [true, false] {
            SubscriptionProtocol.handler = { request in
                if request.url!.path.hasSuffix("/users") {
                    return (200, #"{"code":0,"data":{"items":[{"id":9,"role":"admin"}],"total":1}}"#)
                }
                let amount = includeAdmin ? -1 : (self.query(request)["user_id"] == nil ? 10 : 20)
                return (200, try self.envelope(["total_actual_cost": amount]))
            }
            let result = try await client().loadSubscriptionUsage([request()], includeAdmin: includeAdmin, at: date)
            XCTAssertNil(result.first?.actualCost)
            XCTAssertNotNil(result.first?.error)
        }
    }

    func testAuthenticationFailuresArePropagatedWithoutLeakingBody() async throws {
        for includeAdmin in [true, false] {
            SubscriptionProtocol.handler = { _ in (403, "private-secret-body") }
            do { _ = try await client().loadSubscriptionUsage([request()], includeAdmin: includeAdmin, at: date); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? APIError, .http(403)) }
        }
    }

    func testNoAccountsMakesNoRequestsEvenWhenAdminExcluded() async throws {
        SubscriptionProtocol.handler = { _ in XCTFail("Unexpected request"); return (500, "") }
        let results = try await client().loadSubscriptionUsage([], includeAdmin: false, at: date)
        XCTAssertTrue(results.isEmpty)
    }

    func testRenewalDayIsNotIncludedInPreviousCyclesDateQuery() async throws {
        let lastDay = parseAPIDate("2026-10-14T15:59:59Z")!
        let renewal = parseAPIDate("2026-10-14T16:00:00Z")!
        let old = SubscriptionUsageRequest(accountID: 7, cycle: SubscriptionCycle(renewalDay: 15, at: lastDay, timeZoneID: "Asia/Shanghai")!)
        let new = SubscriptionUsageRequest(accountID: 7, cycle: SubscriptionCycle(renewalDay: 15, at: renewal, timeZoneID: "Asia/Shanghai")!)
        var ranges: [[String]] = []
        SubscriptionProtocol.handler = { request in
            let query = self.query(request)
            ranges.append([query["start_date"] ?? "", query["end_date"] ?? ""])
            return (200, #"{"code":0,"data":{"total_actual_cost":0}}"#)
        }
        _ = try await client().loadSubscriptionUsage([old], includeAdmin: true, at: lastDay)
        _ = try await client().loadSubscriptionUsage([new], includeAdmin: true, at: renewal)
        do {
            _ = try await client().loadSubscriptionUsage([old], includeAdmin: true, at: renewal)
            XCTFail("The old cycle must not accept the next renewal day")
        } catch { XCTAssertEqual(error as? SubscriptionError, .invalidConfiguration) }
        XCTAssertEqual(ranges, [["2026-09-15", "2026-10-14"], ["2026-10-15", "2026-10-15"]])
    }

    func testTodayUsesSingleCalendarDayAndSharedAdminDiscovery() async throws {
        var adminReads = 0
        var dailyUserIDs: [String] = []
        SubscriptionProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let q = self.query(request)
            if request.url!.path.hasSuffix("/users") {
                adminReads += 1
                return (200, try self.envelope(["items": [["id": 9, "role": "admin"], ["id": 42, "role": "admin"]], "total": 2]))
            }
            XCTAssertEqual(request.url?.path, "/api/v1/admin/usage/stats")
            XCTAssertEqual(q["timezone"], "Asia/Shanghai")
            XCTAssertEqual(q["account_id"], "7")
            XCTAssertEqual(q["end_date"], "2026-09-17")
            XCTAssertEqual(q["nocache"], "true")
            let today = q["start_date"] == "2026-09-17"
            if today { dailyUserIDs.append(q["user_id"] ?? "total") }
            else { XCTAssertEqual(q["start_date"], "2026-09-12") }
            let total = today ? 30 : 100
            return (200, try self.envelope(["total_actual_cost": q["user_id"] == nil ? total : 5, "total_cost": 999]))
        }
        let result = try await client().loadSubscriptionUsage([request()], includeAdmin: false, at: date, includeToday: true)
        XCTAssertEqual(adminReads, 1)
        XCTAssertEqual(dailyUserIDs, ["9", "42", "total"])
        XCTAssertEqual(result.first?.actualCost, 90)
        XCTAssertEqual(result.first?.todayActualCost, 20)
    }

    func testTodayAndCycleFailuresAreIndependent() async throws {
        for failedToday in [false, true] {
            SubscriptionProtocol.handler = { request in
                let today = self.query(request)["start_date"] == "2026-09-17"
                return (200, today == failedToday ? #"{"code":0,"data":{"total_cost":999}}"# : #"{"code":0,"data":{"total_actual_cost":0}}"#)
            }
            let result = try await client().loadSubscriptionUsage([request()], includeAdmin: true, at: date, includeToday: true)[0]
            XCTAssertEqual(result.actualCost, failedToday ? 0 : nil)
            XCTAssertEqual(result.todayActualCost, failedToday ? nil : 0)
            XCTAssertEqual(result.todayError != nil, failedToday)
            XCTAssertEqual(result.error != nil, !failedToday)
        }
    }

    func testRenewalDayReusesIdenticalRangeWithoutDoubleCounting() async throws {
        let renewal = parseAPIDate("2026-09-11T16:00:00Z")!
        var calls = 0
        SubscriptionProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(self.query(request)["start_date"], "2026-09-12")
            XCTAssertEqual(self.query(request)["end_date"], "2026-09-12")
            return (200, #"{"code":0,"data":{"total_actual_cost":12.34}}"#)
        }
        let result = try await client().loadSubscriptionUsage([request()], includeAdmin: true, at: renewal, includeToday: true)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.first?.actualCost, result.first?.todayActualCost)
        XCTAssertEqual(result.first?.todayActualCost, Decimal(string: "12.34"))
    }

    func testTodayUsesReportingTimezoneAcrossDSTAndUTCDateBoundary() async throws {
        for (instant, expected) in [("2026-03-08T07:59:59Z", "2026-03-07"), ("2026-03-08T08:00:00Z", "2026-03-08"),
                                     ("2026-03-09T06:59:59Z", "2026-03-08"), ("2026-03-09T07:00:00Z", "2026-03-09")] {
            let now = parseAPIDate(instant)!
            let request = SubscriptionUsageRequest(accountID: 7, cycle: SubscriptionCycle(renewalDay: 1, at: now, timeZoneID: "America/Los_Angeles")!)
            var dayQueries = 0
            SubscriptionProtocol.handler = { req in
                let q = self.query(req)
                if q["start_date"] == q["end_date"] {
                    dayQueries += 1
                    XCTAssertEqual(q["start_date"], expected)
                    XCTAssertEqual(q["timezone"], "America/Los_Angeles")
                }
                return (200, #"{"code":0,"data":{"total_actual_cost":0}}"#)
            }
            _ = try await client().loadSubscriptionUsage([request], includeAdmin: true, at: now, includeToday: true)
            XCTAssertEqual(dayQueries, 1)
        }
    }
}
