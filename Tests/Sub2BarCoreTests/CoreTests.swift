import XCTest
@testable import Sub2BarCore

final class CoreTests: XCTestCase {
    func testQuotaIntervalDefaultsToThirtySecondsAndSupportsFiveSeconds() {
        XCTAssertEqual(Configuration().refreshInterval, 30)
        XCTAssertEqual(Configuration(refreshInterval: 5).effectiveRefreshInterval, 5)
        XCTAssertEqual(Configuration(refreshInterval: 1).effectiveRefreshInterval, 5)
        XCTAssertEqual(Configuration(refreshInterval: 1000).effectiveRefreshInterval, 120)
        XCTAssertEqual(Configuration(refreshInterval: .nan).effectiveRefreshInterval, 30)
        XCTAssertEqual(Configuration(refreshInterval: .infinity).effectiveRefreshInterval, 30)
        XCTAssertEqual(Configuration(refreshInterval: 6).effectiveRefreshInterval, 10)
    }

    func testRefreshIntervalRoundTripPreservesNewAndExistingChoices() throws {
        for interval in [5.0, 10, 15, 30, 60, 120, 300, 600] {
            let original = Configuration(serverURL: "https://example.com", refreshInterval: interval)
            let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(restored.refreshInterval, interval)
            XCTAssertEqual(restored.effectiveRefreshInterval, min(interval, 120))
        }
    }

    func testLegacyConfigurationRetainsQuotaIntervalAndAddsAccountDefault() throws {
        let data = Data(#"{"serverURL":"https://example.invalid","refreshInterval":5,"allowHTTP":false}"#.utf8)
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(config.refreshInterval, 5)
        XCTAssertEqual(config.effectiveAccountRefreshInterval, 2)
    }

    func testAccountIntervalRoundTripsAndClamps() throws {
        for interval in Configuration.accountIntervals {
            let config = Configuration(accountRefreshInterval: interval)
            let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(restored.effectiveAccountRefreshInterval, interval)
        }
        XCTAssertEqual(Configuration(accountRefreshInterval: 0).effectiveAccountRefreshInterval, 2)
        XCTAssertEqual(Configuration(accountRefreshInterval: 3).effectiveAccountRefreshInterval, 5)
        XCTAssertEqual(Configuration(accountRefreshInterval: 300).effectiveAccountRefreshInterval, 30)
        XCTAssertEqual(Configuration(accountRefreshInterval: .nan).effectiveAccountRefreshInterval, 2)
    }

    func testStatisticsIntervalDefaultsAndMigrationAreIndependentOfQuota() throws {
        XCTAssertEqual(Configuration().effectiveStatisticsRefreshInterval, 2)
        XCTAssertEqual(Configuration().effectiveRefreshInterval, 30)
        let legacy = Data(#"{"serverURL":"https://example.invalid","refreshInterval":60,"accountRefreshInterval":5}"#.utf8)
        let restored = try JSONDecoder().decode(Configuration.self, from: legacy)
        XCTAssertEqual(restored.effectiveStatisticsRefreshInterval, 2)
        XCTAssertEqual(restored.refreshInterval, 60)
        XCTAssertEqual(restored.accountRefreshInterval, 5)
        for interval in Configuration.statisticsIntervals {
            let config = Configuration(statisticsRefreshInterval: interval)
            let value = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(value.effectiveStatisticsRefreshInterval, interval)
        }
        for (input, expected) in [(0.0, 2.0), (3, 5), (300, 120), (.nan, 2), (.infinity, 2)] {
            XCTAssertEqual(Configuration(statisticsRefreshInterval: input).effectiveStatisticsRefreshInterval, expected)
        }
    }

    func testURLNormalizationAndProxyPrefix() throws {
        for suffix in ["", "/", "/api/v1", "/api/v1/", "/api/v1/admin/"] {
            let config = Configuration(serverURL: " https://example.com/sub2api\(suffix) ")
            XCTAssertEqual(try config.endpoint("accounts").absoluteString, "https://example.com/sub2api/api/v1/admin/accounts")
        }
    }

    func testRejectsUnsafeURLs() {
        for url in ["example.com", "file:///etc/passwd", "https://user:secret@example.com", "https://example.com?key=x", "https://example.com/#admin", ""] {
            XCTAssertThrowsError(try Configuration(serverURL: url).baseURL())
        }
        XCTAssertThrowsError(try Configuration(serverURL: "http://localhost:8080").baseURL()) {
            XCTAssertEqual($0 as? APIError, .insecureHTTP)
        }
    }

    func testExplicitHTTPAndQuery() throws {
        let config = Configuration(serverURL: "http://127.0.0.1:8080", allowHTTP: true)
        XCTAssertEqual(try config.endpoint("accounts", query: [.init(name: "page", value: "2")]).absoluteString,
                       "http://127.0.0.1:8080/api/v1/admin/accounts?page=2")
    }

    func testUsageEstimateAndFractionalDate() throws {
        let usage = try decodeUsage(#"{"seven_day":{"utilization":25,"resets_at":"2026-09-18T08:30:00.123Z","window_stats":{"cost":20}},"five_hour":{"utilization":125.5}}"#)
        XCTAssertEqual(usage.sevenDay?.estimatedTotalCost, 80)
        XCTAssertNotNil(usage.sevenDay?.resetDate)
        XCTAssertEqual(usage.fiveHour?.percentage, 125.5)
    }

    func testZeroOrMissingUsageDoesNotInventQuota() throws {
        for json in [#"{"seven_day":{"utilization":0,"window_stats":{"cost":20}}}"#,
                     #"{"seven_day":{"utilization":20}}"#,
                     #"{"seven_day":{"utilization":-1,"window_stats":{"cost":20}}}"#,
                     #"{"seven_day":{"utilization":20,"window_stats":{"cost":0}}}"#,
                     #"{}"#] {
            XCTAssertNil(try decodeUsage(json).sevenDay?.estimatedTotalCost)
        }
    }

    func testMissingConcurrencyIsNotZero() throws {
        let account = try makeDecoder().decode(Account.self, from: Data(#"{"id":1,"name":"A","platform":"openai"}"#.utf8))
        XCTAssertNil(account.currentConcurrency)
        XCTAssertFalse(account.isAvailable)
    }

    func testLocalQuotaFallbackAndProviderEstimateRestriction() throws {
        let account = try makeDecoder().decode(Account.self, from: Data(#"{"id":1,"name":"A","platform":"anthropic","quota_weekly_limit":200,"quota_weekly_used":50}"#.utf8))
        let usage = try decodeUsage(#"{"seven_day":{"utilization":25,"window_stats":{"cost":20}}}"#)
        XCTAssertNil(AccountSnapshot(account: account, usage: usage).estimatedWeeklyCost)
        XCTAssertEqual(AccountSnapshot(account: account, usage: nil).weeklyPercentage, 25)
    }

    func testDatesAndUpstreamErrors() throws {
        XCTAssertNotNil(parseAPIDate("2026-09-18T08:30:00Z"))
        XCTAssertNil(parseAPIDate("bad date"))
        XCTAssertTrue(try decodeUsage(#"{"needs_reauth":true}"#).hasError)
        XCTAssertTrue(try decodeUsage(#"{"error_code":"unavailable"}"#).hasError)
        XCTAssertFalse(try decodeUsage(#"{}"#).hasError)
    }

    func testCachedCodexPercentagesAndFixedResetDeadline() throws {
        let json = #"{"id":1,"name":"A","platform":"openai","extra":{"codex_5h_used_percent":"75.5","codex_5h_reset_after_seconds":3600,"codex_7d_used_percent":42,"codex_7d_reset_at":"2026-09-20T10:00:00Z","codex_usage_updated_at":"2026-09-15T10:00:00Z","ignored_object":{"secret":"never-retained"}}}"#
        let account = try makeDecoder().decode(Account.self, from: Data(json.utf8))
        let now = parseAPIDate("2026-09-15T10:30:00Z")!
        let usage = try XCTUnwrap(account.extra?.usage(at: now))
        XCTAssertEqual(usage.fiveHour?.percentage, 75.5)
        XCTAssertEqual(usage.fiveHour?.remainingSeconds, 1800)
        XCTAssertEqual(usage.fiveHour?.resetDate, parseAPIDate("2026-09-15T11:00:00Z"))
        XCTAssertEqual(usage.sevenDay?.percentage, 42)
        XCTAssertEqual(account.extra?.usage(at: now.addingTimeInterval(3600)).fiveHour?.percentage, 0)
    }
    func testUnknownCacheDoesNotInventPercentageOrSlidingReset() throws {
        let json = #"{"id":1,"name":"A","platform":"openai","extra":{"codex_5h_used_percent":35,"codex_5h_reset_after_seconds":3600,"codex_7d_used_percent":"bad"}}"#
        let account = try makeDecoder().decode(Account.self, from: Data(json.utf8))
        XCTAssertNil(account.extra?.usage(at: Date()).fiveHour?.resetDate)
        XCTAssertNil(account.extra?.usage(at: Date()).sevenDay)
    }
    func testNewPercentAndOlderCostsNeverMixForEstimate() throws {
        let account = try makeDecoder().decode(Account.self, from: Data(#"{"id":1,"name":"A","platform":"openai"}"#.utf8))
        let cached = UsageInfo(sevenDay: UsageWindow(utilization: 90))
        let stats = try decodeUsage(#"{"seven_day":{"utilization":25,"window_stats":{"cost":20}}}"#)
        let snapshot = AccountSnapshot(account: account, usage: cached, statisticsUsage: stats)
        XCTAssertEqual(snapshot.weeklyPercentage, 90)
        XCTAssertEqual(snapshot.estimatedWeeklyCost, 80)
        XCTAssertEqual(snapshot.weeklyCost, 20)
    }
    func testStatusIncludesDisabledErrorRateLimitAndTemporaryCooldown() throws {
        let now = parseAPIDate("2026-09-15T10:00:00Z")!
        let cases = [(#""status":"inactive""#, "已停用"), (#""status":"error""#, "错误"),
                     (#""status":"active","rate_limit_reset_at":"2026-09-15T11:00:00Z""#, "限流中"),
                     (#""status":"active","temp_unschedulable_until":"2026-09-15T11:00:00Z""#, "暂不可调度"),
                     (#""status":"active","schedulable":false"#, "已停调度")]
        for (fields, label) in cases {
            let data = Data((#"{"id":1,"name":"A","platform":"openai","# + fields + "}").utf8)
            let account = try makeDecoder().decode(Account.self, from: data)
            XCTAssertEqual(account.stateLabel(at: now), label)
        }
    }

    private func decodeUsage(_ value: String) throws -> UsageInfo {
        try makeDecoder().decode(UsageInfo.self, from: Data(value.utf8))
    }
}

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class APIClientTests: XCTestCase {
    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return APIClient(configuration: Configuration(serverURL: "https://example.com"), key: "test-admin-key", session: URLSession(configuration: config))
    }
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }

    func testAdminHeaderAndReadOnlyConnectionTest() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-admin-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/admin/accounts")
            return (200, #"{"code":0,"data":{"items":[],"total":12,"pages":12}}"#)
        }
        let count = try await client().testConnection()
        XCTAssertEqual(count, 12)
    }

    func testAllPagesAreLoadedAndDeduplicated() async throws {
        StubProtocol.handler = { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value
            let items = page == "1" ? #"[{"id":1,"name":"A","platform":"openai"}]"# : #"[{"id":1,"name":"A","platform":"openai"},{"id":2,"name":"B","platform":"openai"}]"#
            return (200, "{\"code\":0,\"data\":{\"items\":\(items),\"total\":2,\"pages\":2}}")
        }
        let accounts = try await client().loadAccounts()
        XCTAssertEqual(accounts.map(\.id), [1, 2])
    }

    func testRepeatedPageDoesNotLoopForever() async {
        StubProtocol.handler = { _ in (200, #"{"code":0,"data":{"items":[{"id":1,"name":"A","platform":"openai"}],"total":2}}"#) }
        do { _ = try await client().loadAccounts(); XCTFail("Expected pagination error") }
        catch { XCTAssertEqual(error as? APIError, .tooManyPages) }
    }

    func testAuthenticationFailureDoesNotExposeServerBody() async {
        StubProtocol.handler = { _ in (401, #"{"message":"private secret"}"#) }
        do { _ = try await client().testConnection(); XCTFail("Expected authentication error") }
        catch {
            XCTAssertEqual(error as? APIError, .http(401))
            XCTAssertFalse(error.localizedDescription.contains("private secret"))
        }
    }

    func testHTMLAndEnvelopeErrors() async {
        for (body, expected) in [("<html>sign in</html>", APIError.invalidResponse), (#"{"code":7}"#, APIError.server(7))] {
            StubProtocol.handler = { _ in (200, body) }
            do { _ = try await client().testConnection(); XCTFail("Expected response error") }
            catch { XCTAssertEqual(error as? APIError, expected) }
        }
    }

    func testPartialFailurePreservesOtherAccountsAndUsesPassiveClaude() async throws {
        StubProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/accounts/1") {
                return (200, #"{"code":0,"data":{"id":1,"name":"A","platform":"anthropic","type":"oauth"}}"#)
            }
            if path.hasSuffix("/accounts/2") {
                return (200, #"{"code":0,"data":{"id":2,"name":"B","platform":"openai","type":"oauth"}}"#)
            }
            if path.contains("/1/usage") {
                XCTAssertTrue(request.url!.absoluteString.contains("source=passive"))
                return (200, #"{"code":0,"data":{"seven_day":{"utilization":35}}}"#)
            }
            XCTAssertTrue(request.url!.absoluteString.contains("source=active"))
            return (503, "unavailable")
        }
        let snapshots = try await client().loadPinnedSnapshot(ids: [1, 2]).snapshots
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].weeklyPercentage, 35)
        XCTAssertNil(snapshots[0].usageError)
        XCTAssertNotNil(snapshots[1].usageError)
    }

    func testUsageAuthFailureInvalidatesWholeRefresh() async {
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("/accounts/1") {
                return (200, #"{"code":0,"data":{"id":1,"name":"A","platform":"openai"}}"#)
            }
            return (403, "forbidden")
        }
        do { _ = try await client().loadPinnedSnapshot(ids: [1]); XCTFail("Expected auth error") }
        catch { XCTAssertEqual(error as? APIError, .http(403)) }
    }

    func testRedirectResponseIsRejected() async {
        StubProtocol.handler = { _ in (302, "") }
        do { _ = try await client().testConnection(); XCTFail("Expected redirect error") }
        catch { XCTAssertEqual(error as? APIError, .http(302)) }
    }

    func testMissingKeyPreventsRequest() async {
        StubProtocol.handler = { _ in XCTFail("Must not send a request"); return (200, "") }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let emptyClient = APIClient(configuration: Configuration(serverURL: "https://example.com"), key: "  ", session: URLSession(configuration: config))
        do { _ = try await emptyClient.testConnection(); XCTFail("Expected missing key") }
        catch { XCTAssertEqual(error as? APIError, .missingKey) }
    }

    func testNoPinsMakesNoRequests() async throws {
        StubProtocol.handler = { _ in XCTFail("No pins must not make any requests"); return (500, "") }
        let result = try await client().loadPinnedSnapshot(ids: [])
        XCTAssertTrue(result.snapshots.isEmpty)
        XCTAssertTrue(result.accountErrors.isEmpty)
    }

    func testRuntimeFetchOnlyCallsAccountDetailsNeverUsage() async throws {
        let log = RequestLog()
        StubProtocol.handler = { request in
            let path = request.url!.path
            log.record(path)
            XCTAssertFalse(path.contains("usage"))
            let id = Int(request.url!.lastPathComponent)!
            return (200, "{\"code\":0,\"data\":{\"id\":\(id),\"name\":\"A\",\"platform\":\"openai\"}}")
        }
        let result = try await client().loadPinnedAccounts(ids: [3, 1, 3])
        XCTAssertEqual(result.snapshots.map(\.id), [3, 1])
        XCTAssertEqual(log.paths.count, 2)
        XCTAssertTrue(result.snapshots.allSatisfy { $0.usage == nil })
    }
    func testPassiveOpenAIIsRejectedBeforeSendingUnsupportedRequest() async throws {
        StubProtocol.handler = { _ in XCTFail("Must not call unsupported passive OpenAI endpoint"); return (500, "") }
        let account = try makeDecoder().decode(Account.self, from: Data(#"{"id":1,"name":"A","platform":"openai"}"#.utf8))
        do { _ = try await client().loadUsage(for: account, passive: true); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? APIError, .invalidResponse) }
    }

    func testOnlyPinnedAccountsAreRequestedWithoutListingAllAccounts() async throws {
        let log = RequestLog()
        StubProtocol.handler = { request in
            let path = request.url!.path
            log.record(path)
            XCTAssertEqual(request.httpMethod, "GET")
            for id in [7, 2] {
                if path == "/api/v1/admin/accounts/\(id)" {
                    return (200, "{\"code\":0,\"data\":{\"id\":\(id),\"name\":\"Account \(id)\",\"platform\":\"openai\",\"current_concurrency\":\(id)}}")
                }
                if path == "/api/v1/admin/accounts/\(id)/usage" { return (200, #"{"code":0,"data":{"seven_day":{"utilization":10}}}"#) }
            }
            XCTFail("Unexpected endpoint: \(path)")
            return (500, "")
        }
        let result = try await client().loadPinnedSnapshot(ids: [7, 2, 7, 0, -1])
        XCTAssertEqual(result.snapshots.map(\.id), [7, 2])
        XCTAssertEqual(result.snapshots.map { $0.account.currentConcurrency }, [7, 2])
        XCTAssertTrue(result.accountErrors.isEmpty)
        XCTAssertEqual(log.paths.count, 4)
        XCTAssertFalse(log.paths.contains("/api/v1/admin/accounts"))
    }

    func testDeletedPinnedAccountDoesNotHideHealthyAccount() async throws {
        StubProtocol.handler = { request in
            switch request.url!.path {
            case "/api/v1/admin/accounts/1": return (404, "gone")
            case "/api/v1/admin/accounts/2": return (200, #"{"code":0,"data":{"id":2,"name":"A","platform":"openai"}}"#)
            case "/api/v1/admin/accounts/2/usage": return (200, #"{"code":0,"data":{}}"#)
            default: XCTFail("Unexpected request"); return (500, "")
            }
        }
        let result = try await client().loadPinnedSnapshot(ids: [1, 2])
        XCTAssertEqual(result.snapshots.map(\.id), [2])
        XCTAssertNotNil(result.accountErrors[1])
    }

    func testWrongAccountResponseNeverAppearsAsPinned() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/api/v1/admin/accounts/1")
            return (200, #"{"code":0,"data":{"id":99,"name":"Wrong","platform":"openai"}}"#)
        }
        let result = try await client().loadPinnedSnapshot(ids: [1])
        XCTAssertTrue(result.snapshots.isEmpty)
        XCTAssertNotNil(result.accountErrors[1])
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ path: String) { lock.withLock { recorded.append(path) } }
    var paths: [String] { lock.withLock { recorded } }
}

final class PinnedSelectionTests: XCTestCase {
    func testMovingPinsChangesOnlyOrderWithinTheChosenServer() throws {
        var pins = PinnedAccountSelection()
        for id in [7, 2, 9] { pins.setPinned(true, id: id, server: "A") }
        pins.setPinned(true, id: 7, server: "B")
        pins.move(id: 9, to: 0, server: "A")
        XCTAssertEqual(pins.ids(for: "A"), [9, 7, 2])
        XCTAssertEqual(pins.ids(for: "B"), [7])
        pins.move(id: 999, to: 0, server: "A")
        pins.move(id: 7, to: -1, server: "A")
        pins.move(id: 7, to: 9, server: "A")
        let restored = try JSONDecoder().decode(PinnedAccountSelection.self, from: JSONEncoder().encode(pins))
        XCTAssertEqual(restored.ids(for: "A"), [9, 7, 2])
    }
    func testPinSelectionPersistsOrderAndSeparatesServers() throws {
        var pins = PinnedAccountSelection()
        pins.setPinned(true, id: 8, server: "https://a.example")
        pins.setPinned(true, id: 3, server: "https://a.example")
        pins.setPinned(true, id: 8, server: "https://a.example")
        pins.setPinned(true, id: 4, server: "https://b.example")
        let restored = try JSONDecoder().decode(PinnedAccountSelection.self, from: JSONEncoder().encode(pins))
        XCTAssertEqual(restored.ids(for: "https://a.example"), [8, 3])
        XCTAssertEqual(restored.ids(for: "https://b.example"), [4])
        XCTAssertTrue(restored.ids(for: "https://new.example").isEmpty)
    }

    func testUnpinAllStaysEmptyAndInvalidIDsAreIgnored() {
        var pins = PinnedAccountSelection()
        pins.setPinned(true, id: 8, server: "A")
        pins.setPinned(false, id: 8, server: "A")
        pins.setPinned(true, id: -1, server: "A")
        pins.setPinned(true, id: 0, server: "A")
        XCTAssertTrue(pins.ids(for: "A").isEmpty)
    }
}
