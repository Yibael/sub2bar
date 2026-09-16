import XCTest
import Sub2BarCore
@testable import Sub2Bar

actor MemoryVault: CredentialStorage {
    var values: [String: String]
    var reads = 0
    var writes = 0
    var denied = false
    var holding = false
    var pending: [CheckedContinuation<String, Error>] = []
    init(values: [String: String] = ["https://example.invalid": "fake-secret"]) { self.values = values }
    func read(for server: String) async throws -> String {
        reads += 1
        if denied { throw LocalCredentialError.unavailable }
        if holding { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return values[server] ?? ""
    }
    func write(_ key: String, for server: String) async throws { writes += 1; values[server] = key }
    func counts() -> (reads: Int, writes: Int) { (reads, writes) }
    func deny() { denied = true }
    func hold() { holding = true }
    func complete(_ key: String) { let items = pending; pending = []; for item in items { item.resume(returning: key) } }
}

final class MockBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var _concurrency = 1
    private var _percentage = 40.0
    private var _status = "active"
    private var _error = 0
    private var _usageError = 0
    private var _platform = "openai"
    private var _delayActive = 0.0
    private var _delayRuntime = 0.0
    var concurrency: Int { get { lock.withLock { _concurrency } } set { lock.withLock { _concurrency = newValue } } }
    var percentage: Double { get { lock.withLock { _percentage } } set { lock.withLock { _percentage = newValue } } }
    var status: String { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    var error: Int { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
    var usageError: Int { get { lock.withLock { _usageError } } set { lock.withLock { _usageError = newValue } } }
    var platform: String { get { lock.withLock { _platform } } set { lock.withLock { _platform = newValue } } }
    var delayActive: Double { get { lock.withLock { _delayActive } } set { lock.withLock { _delayActive = newValue } } }
    var delayRuntime: Double { get { lock.withLock { _delayRuntime } } set { lock.withLock { _delayRuntime = newValue } } }
    var requests: [String] { lock.withLock { paths } }
    var activeCount: Int { requests.filter { $0.contains("source=active") }.count }
    var passiveCount: Int { requests.filter { $0.contains("source=passive") }.count }
    var detailCount: Int { requests.filter { !$0.contains("usage") && !$0.contains("?") }.count }

    func response(_ request: URLRequest) -> (Int, String, Double) {
        lock.withLock {
            let url = request.url!
            paths.append(url.path + (url.query.map { "?" + $0 } ?? ""))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fake-secret")
            XCTAssertFalse(url.absoluteString.contains("force=true"))
            if _error > 0 { return (_error, "private-secret-error", 0) }
            if url.path.hasSuffix("/usage") {
                if _usageError > 0 { return (_usageError, "private-secret-error", 0) }
                return (200, #"{"code":0,"data":{"updated_at":"2026-09-15T10:00:00Z","five_hour":{"utilization":20},"seven_day":{"utilization":50,"window_stats":{"cost":25}}}}"#,
                        url.query?.contains("source=active") == true ? _delayActive : 0)
            }
            let id = Int(url.lastPathComponent) ?? 1
            let item = "{\"id\":\(id),\"name\":\"Account \(id)\",\"platform\":\"\(_platform)\",\"type\":\"oauth\",\"status\":\"\(_status)\",\"schedulable\":true,\"concurrency\":5,\"current_concurrency\":\(_concurrency),\"extra\":{\"codex_5h_used_percent\":10,\"codex_7d_used_percent\":\(_percentage),\"codex_usage_updated_at\":\"2026-09-15T10:00:00Z\",\"codex_7d_reset_at\":\"2026-09-20T10:00:00Z\"}}"
            if url.path.hasSuffix("/accounts") { return (200, "{\"code\":0,\"data\":{\"items\":[\(item)],\"total\":1}}", 0) }
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
    init(ids: [Int] = [1], interval: Double = 5, vault: MemoryVault = MemoryVault(), automatic: Bool = false) throws {
        defaults = UserDefaults(suiteName: name)!; self.vault = vault
        defaults.set(try JSONEncoder().encode(Configuration(serverURL: "https://example.invalid", refreshInterval: interval)), forKey: "sub2bar.configuration.v1")
        var pins = PinnedAccountSelection()
        for id in ids { pins.setPinned(true, id: id, server: "https://example.invalid") }
        defaults.set(try JSONEncoder().encode(pins), forKey: "sub2bar.pins.v1")
        MonitorURLProtocol.backend = backend
        store = AppStore(defaults: defaults, credentials: CredentialSession(storage: vault), now: { [weak self] in self!.date }, automaticallySchedule: automatic,
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
        await until { self.backend.detailCount > previous && !self.store.isRefreshing && !self.store.isRefreshingQuota && !self.store.isRefreshingUpstream }
    }
    func tick(_ seconds: Double) async {
        date = date.addingTimeInterval(seconds)
        store.runDueRefreshes()
        await until { !self.store.isRefreshing && !self.store.isRefreshingQuota && !self.store.isRefreshingUpstream }
    }
}
