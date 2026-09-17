import XCTest
import Sub2BarCore
@testable import Sub2Bar

actor MemoryVault: CredentialStorage {
    var values: [String: String]
    var reads = 0
    var writes = 0
    var denied = false
    var writesDenied = false
    var holding = false
    var pending: [CheckedContinuation<String, Error>] = []
    init(values: [String: String] = ["https://example.invalid": "fake-secret"]) { self.values = values }
    func read(for server: String) async throws -> String {
        reads += 1
        if denied { throw LocalCredentialError.unavailable }
        if holding { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return values[server] ?? ""
    }
    func write(_ key: String, for server: String) async throws {
        writes += 1
        if writesDenied { throw LocalCredentialError.unavailable }
        values[server] = key
    }
    func counts() -> (reads: Int, writes: Int) { (reads, writes) }
    func deny() { denied = true }
    func denyWrites() { writesDenied = true }
    func hold() { holding = true }
    func complete(_ key: String) { let items = pending; pending = []; for item in items { item.resume(returning: key) } }
}

final class MockBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var _concurrency = 1
    private var _percentage = 40.0
    private var _usagePercentage = 50.0
    private var _usageCost = 25.0
    private var _todayCost = 12.0
    private var _todayError = 0
    private var _missingTodayIDs: Set<Int> = []
    private var _delayToday = 0.0
    private var todayBatches: [[Int]] = []
    private var _actualCost = 100.0
    private var _todayActualCost = 30.0
    private var _todayAdminCost = 5.0
    private var _todayStatsError = 0
    private var _failedTodayStatsIDs: Set<Int> = []
    private var _delayTodayStats = 0.0
    private var _adminCost = 20.0
    private var _statsError = 0
    private var _usersError = 0
    private var _failedStatsIDs: Set<Int> = []
    private var _delayStats = 0.0
    private var _delayAccounts = 0.0
    private var _directoryIDs = [1]
    private var _directoryItems: [[String: Any]]?
    private var _batchUnavailable = false
    private var batches: [[Int]] = []
    private var _status = "active"
    private var _error = 0
    private var _usageError = 0
    private var _failedUsageIDs: Set<Int> = []
    private var _platform = "openai"
    private var _delayActive = 0.0
    private var _delayPassive = 0.0
    private var _delayRuntime = 0.0
    var concurrency: Int { get { lock.withLock { _concurrency } } set { lock.withLock { _concurrency = newValue } } }
    var percentage: Double { get { lock.withLock { _percentage } } set { lock.withLock { _percentage = newValue } } }
    var usagePercentage: Double { get { lock.withLock { _usagePercentage } } set { lock.withLock { _usagePercentage = newValue } } }
    var usageCost: Double { get { lock.withLock { _usageCost } } set { lock.withLock { _usageCost = newValue } } }
    var todayCost: Double { get { lock.withLock { _todayCost } } set { lock.withLock { _todayCost = newValue } } }
    var todayError: Int { get { lock.withLock { _todayError } } set { lock.withLock { _todayError = newValue } } }
    var missingTodayIDs: Set<Int> { get { lock.withLock { _missingTodayIDs } } set { lock.withLock { _missingTodayIDs = newValue } } }
    var delayToday: Double { get { lock.withLock { _delayToday } } set { lock.withLock { _delayToday = newValue } } }
    var todayBatchIDs: [[Int]] { lock.withLock { todayBatches } }
    var todayCount: Int { requests.filter { $0.hasSuffix("/today-stats/batch") }.count }
    var actualCost: Double { get { lock.withLock { _actualCost } } set { lock.withLock { _actualCost = newValue } } }
    var todayActualCost: Double { get { lock.withLock { _todayActualCost } } set { lock.withLock { _todayActualCost = newValue } } }
    var todayAdminCost: Double { get { lock.withLock { _todayAdminCost } } set { lock.withLock { _todayAdminCost = newValue } } }
    var todayStatsError: Int { get { lock.withLock { _todayStatsError } } set { lock.withLock { _todayStatsError = newValue } } }
    var failedTodayStatsIDs: Set<Int> { get { lock.withLock { _failedTodayStatsIDs } } set { lock.withLock { _failedTodayStatsIDs = newValue } } }
    var delayTodayStats: Double { get { lock.withLock { _delayTodayStats } } set { lock.withLock { _delayTodayStats = newValue } } }
    var adminCost: Double { get { lock.withLock { _adminCost } } set { lock.withLock { _adminCost = newValue } } }
    var statsError: Int { get { lock.withLock { _statsError } } set { lock.withLock { _statsError = newValue } } }
    var usersError: Int { get { lock.withLock { _usersError } } set { lock.withLock { _usersError = newValue } } }
    var failedStatsIDs: Set<Int> { get { lock.withLock { _failedStatsIDs } } set { lock.withLock { _failedStatsIDs = newValue } } }
    var delayStats: Double { get { lock.withLock { _delayStats } } set { lock.withLock { _delayStats = newValue } } }
    var statsCount: Int { requests.filter { $0.contains("/usage/stats?") }.count }
    var usersCount: Int { requests.filter { $0.contains("/users?") }.count }
    var directoryCount: Int { requests.filter { $0.contains("/accounts?") }.count }
    var delayAccounts: Double { get { lock.withLock { _delayAccounts } } set { lock.withLock { _delayAccounts = newValue } } }
    var directoryIDs: [Int] { get { lock.withLock { _directoryIDs } } set { lock.withLock { _directoryIDs = newValue } } }
    var directoryItems: [[String: Any]]? { get { lock.withLock { _directoryItems } } set { lock.withLock { _directoryItems = newValue } } }
    var batchUnavailable: Bool { get { lock.withLock { _batchUnavailable } } set { lock.withLock { _batchUnavailable = newValue } } }
    var batchIDs: [[Int]] { lock.withLock { batches } }
    var batchCount: Int { requests.filter { $0.hasSuffix("/usage/batch") }.count }
    var status: String { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    var error: Int { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
    var usageError: Int { get { lock.withLock { _usageError } } set { lock.withLock { _usageError = newValue } } }
    var failedUsageIDs: Set<Int> { get { lock.withLock { _failedUsageIDs } } set { lock.withLock { _failedUsageIDs = newValue } } }
    var platform: String { get { lock.withLock { _platform } } set { lock.withLock { _platform = newValue } } }
    var delayActive: Double { get { lock.withLock { _delayActive } } set { lock.withLock { _delayActive = newValue } } }
    var delayPassive: Double { get { lock.withLock { _delayPassive } } set { lock.withLock { _delayPassive = newValue } } }
    var delayRuntime: Double { get { lock.withLock { _delayRuntime } } set { lock.withLock { _delayRuntime = newValue } } }
    var requests: [String] { lock.withLock { paths } }
    var activeCount: Int { requests.filter { $0.contains("source=active") }.count }
    var passiveCount: Int { requests.filter { $0.contains("source=passive") }.count }
    var detailCount: Int { requests.filter { !$0.contains("usage") && !$0.contains("today-stats") && !$0.contains("?") }.count }

    func response(_ request: URLRequest) -> (Int, String, Double) {
        lock.withLock {
            let url = request.url!
            paths.append(url.path + (url.query.map { "?" + $0 } ?? ""))
            let isBatch = url.path.hasSuffix("/usage/batch")
            let isTodayBatch = url.path.hasSuffix("/today-stats/batch")
            XCTAssertEqual(request.httpMethod, isBatch || isTodayBatch ? "POST" : "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fake-secret")
            XCTAssertFalse(url.absoluteString.contains("force=true"))
            if _error > 0 { return (_error, "private-secret-error", 0) }
            if url.path.hasSuffix("/users") {
                if _usersError > 0 { return (_usersError, "private-secret-error", 0) }
                return (200, #"{"code":0,"data":{"items":[{"id":9,"role":"admin"}],"total":1}}"#, 0)
            }
            if url.path.hasSuffix("/usage/stats") {
                let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["nocache"], "true")
                XCTAssertNotNil(query["timezone"])
                let id = Int(query["account_id"] ?? "") ?? 0
                if _statsError > 0 { return (_statsError, "private-secret-error", _delayStats) }
                if _failedStatsIDs.contains(id) { return (503, "private-secret-error", _delayStats) }
                let today = query["start_date"] == query["end_date"]
                if today && _todayStatsError > 0 { return (_todayStatsError, "private-secret-error", _delayTodayStats) }
                if today && _failedTodayStatsIDs.contains(id) { return (503, "private-secret-error", _delayTodayStats) }
                let cost = today ? (query["user_id"] == nil ? _todayActualCost : _todayAdminCost) :
                    (query["user_id"] == nil ? _actualCost : _adminCost)
                return (200, "{\"code\":0,\"data\":{\"total_actual_cost\":\(cost),\"total_cost\":999}}", today ? _delayTodayStats : _delayStats)
            }
            if isTodayBatch {
                let body = (try? JSONSerialization.jsonObject(with: testRequestBody(request))) as? [String: Any]
                let ids = body?["account_ids"] as? [Int] ?? []
                XCTAssertFalse(ids.isEmpty)
                XCTAssertNil(body?["force"])
                todayBatches.append(ids)
                if _todayError > 0 { return (_todayError, "private-secret-error", _delayToday) }
                let values = Dictionary(uniqueKeysWithValues: ids.filter { !_missingTodayIDs.contains($0) }.map {
                    (String($0), ["standard_cost": _todayCost, "cost": 98.0, "user_cost": 76.0])
                })
                let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": ["stats": values]])
                return (200, String(decoding: data, as: UTF8.self), _delayToday)
            }
            let usage: [String: Any] = ["updated_at": "2026-09-15T10:00:00Z", "five_hour": ["utilization": 20],
                                       "seven_day": ["utilization": _usagePercentage, "window_stats": ["cost": _usageCost]]]
            if isBatch {
                let body = (try? JSONSerialization.jsonObject(with: testRequestBody(request))) as? [String: Any]
                XCTAssertEqual(body?["force"] as? Bool, false)
                let ids = body?["account_ids"] as? [Int] ?? []
                XCTAssertFalse(ids.isEmpty)
                batches.append(ids)
                if _batchUnavailable { return (404, "not found", 0) }
                if _usageError > 0 { return (_usageError, "private-secret-error", 0) }
                let values = Dictionary(uniqueKeysWithValues: ids.filter { !_failedUsageIDs.contains($0) }.map { (String($0), usage) })
                let errors = Dictionary(uniqueKeysWithValues: ids.filter { _failedUsageIDs.contains($0) }.map { (String($0), "unavailable") })
                let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": ["usage": values, "errors": errors]])
                return (200, String(decoding: data, as: UTF8.self), _platform == "anthropic" ? _delayPassive : _delayActive)
            }
            if url.path.hasSuffix("/usage") {
                XCTAssertTrue(url.absoluteString.contains("force=false"))
                if _usageError > 0 { return (_usageError, "private-secret-error", 0) }
                let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": usage])
                return (200, String(decoding: data, as: UTF8.self),
                        url.query?.contains("source=active") == true ? _delayActive : _delayPassive)
            }
            let id = Int(url.lastPathComponent) ?? 1
            let item = "{\"id\":\(id),\"name\":\"Account \(id)\",\"platform\":\"\(_platform)\",\"type\":\"oauth\",\"status\":\"\(_status)\",\"schedulable\":true,\"concurrency\":5,\"current_concurrency\":\(_concurrency),\"extra\":{\"codex_5h_used_percent\":10,\"codex_7d_used_percent\":\(_percentage),\"codex_usage_updated_at\":\"2026-09-15T10:00:00Z\",\"codex_7d_reset_at\":\"2026-09-20T10:00:00Z\"}}"
            if url.path.hasSuffix("/accounts") {
                let items: [[String: Any]] = _directoryItems ?? _directoryIDs.map { ["id": $0, "name": "Account \($0)", "platform": _platform,
                    "type": "oauth", "status": _status, "schedulable": true, "concurrency": 5, "current_concurrency": _concurrency] }
                let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": ["items": items, "total": items.count]])
                return (200, String(decoding: data, as: UTF8.self), _delayAccounts)
            }
            return (200, "{\"code\":0,\"data\":\(item)}", _delayRuntime)
        }
    }
}

final class MonitorURLProtocol: URLProtocol, @unchecked Sendable {
    static var backend = MockBackend()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body, delay) = Self.backend.response(request)
        let deliver: @Sendable () -> Void = { [self] in
            lock.withLock {
                guard !stopped else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
            }
        }
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver) }
        else { deliver() }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

@MainActor
final class StoreFixture {
    let name = "com.sub2bar.test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let vault: MemoryVault
    let backend = MockBackend()
    var date = parseAPIDate("2026-09-15T10:00:00Z")!
    var store: AppStore!
    init(ids: [Int] = [1], interval: Double = 5, vault: MemoryVault = MemoryVault(), automatic: Bool = false,
         accountInterval: Double = 2, statisticsInterval: Double = 30) throws {
        defaults = UserDefaults(suiteName: name)!; self.vault = vault
        defaults.set(try JSONEncoder().encode(Configuration(serverURL: "https://example.invalid", refreshInterval: interval,
            accountRefreshInterval: accountInterval, statisticsRefreshInterval: statisticsInterval)), forKey: "sub2bar.configuration.v1")
        var pins = PinnedAccountSelection()
        for id in ids { pins.setPinned(true, id: id, server: "https://example.invalid") }
        defaults.set(try JSONEncoder().encode(pins), forKey: "sub2bar.pins.v1")
        MonitorURLProtocol.backend = backend
        store = AppStore(defaults: defaults, credentials: CredentialSession(storage: vault), now: { [weak self] in self?.date ?? Date() }, automaticallySchedule: automatic,
                         clientFactory: { config, key in
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [MonitorURLProtocol.self]
            return APIClient(configuration: config, key: key, session: URLSession(configuration: sessionConfig))
        })
    }
    func cleanup() { store.setPanelVisible(false); defaults.removePersistentDomain(forName: name) }
    func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<3000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("State did not settle", file: file, line: line)
    }
    func open() async {
        let previous = backend.detailCount
        store.setPanelVisible(true)
        await until { self.backend.detailCount > previous && !self.store.isRefreshing && !self.store.isRefreshingQuota }
    }
    func tick(_ seconds: Double) async {
        date = date.addingTimeInterval(seconds)
        store.runDueRefreshes()
        await until { !self.store.isRefreshing && !self.store.isRefreshingQuota }
    }
}

func testRequestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(); var bytes = [UInt8](repeating: 0, count: 1024)
    while data.count < 65_536 {
        let count = stream.read(&bytes, maxLength: bytes.count)
        if count <= 0 { break }
        data.append(contentsOf: bytes.prefix(count))
    }
    return data
}
