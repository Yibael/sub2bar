import Foundation

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class APIClient: @unchecked Sendable {
    public let configuration: Configuration
    private let key: String
    private let session: URLSession

    public init(configuration: Configuration, key: String, session: URLSession? = nil) {
        self.configuration = configuration
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        }
    }

    deinit { session.invalidateAndCancel() }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await request(path, query: query)
    }

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> T {
        try Task.checkCancellation()
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw APIError.missingKey }
        var request = URLRequest(url: try configuration.endpoint(path, query: query))
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw APIError.network
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        let envelope: APIEnvelope<T>
        do { envelope = try makeDecoder().decode(APIEnvelope<T>.self, from: data) }
        catch { throw APIError.invalidResponse }
        guard envelope.code == 0 else { throw APIError.server(envelope.code) }
        guard let payload = envelope.data else { throw APIError.invalidResponse }
        return payload
    }

    public func testConnection() async throws -> Int {
        let page: AccountPage = try await get("accounts", query: listQuery(page: 1, size: 1))
        return page.total
    }

    private func listQuery(page: Int, size: Int = 100) -> [URLQueryItem] {
        [URLQueryItem(name: "page", value: String(page)),
         URLQueryItem(name: "page_size", value: String(size)),
         URLQueryItem(name: "lite", value: "true"),
         URLQueryItem(name: "include_scheduler_score", value: "false")]
    }

    public func loadAccounts() async throws -> [Account] {
        var accounts: [Account] = []
        var seen = Set<Int>()
        for index in 1...100 {
            try Task.checkCancellation()
            let page: AccountPage = try await get("accounts", query: listQuery(page: index))
            let new = page.items.filter { seen.insert($0.id).inserted }
            accounts.append(contentsOf: new)
            if accounts.count >= page.total { return accounts }
            guard !new.isEmpty else { throw APIError.tooManyPages }
        }
        throw APIError.tooManyPages
    }

    /// Runtime / status polling only. Does not call /usage or list all accounts.
    public func loadPinnedAccounts(ids: [Int]) async throws -> PinnedSnapshotResult {
        try await fetchPinned(ids: ids, includeUsage: false)
    }

    public func loadUsage(for account: Account, passive: Bool) async throws -> UsageInfo {
        // There is no OpenAI cache-only /usage endpoint in the audited backend.
        guard !passive || account.supportsPassiveUsage else { throw APIError.invalidResponse }
        return try await get("accounts/\(account.id)/usage", query: [
            URLQueryItem(name: "source", value: passive ? "passive" : "active"),
            URLQueryItem(name: "force", value: "false")
        ])
    }

    /// Read-only batch query. Never expose upstream error bodies to the UI.
    public func loadUsageBatch(ids: [Int]) async throws -> [AccountUsageResult] {
        struct Body: Encodable { let account_ids: [Int]; let force = false }
        struct Payload: Decodable { let usage: [String: UsageInfo]; let errors: [String: String]? }
        var seen = Set<Int>()
        let ids = ids.filter { $0 > 0 && seen.insert($0).inserted }
        var results: [AccountUsageResult] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            let data = try JSONEncoder().encode(Body(account_ids: chunk))
            let response: Payload = try await request("accounts/usage/batch", method: "POST", body: data)
            for id in chunk {
                let value = response.usage[String(id)]
                let failed = response.errors?[String(id)] != nil || value == nil || value?.hasError == true
                results.append(AccountUsageResult(id: id, usage: failed ? nil : value,
                                                  error: failed ? "额度读取失败" : nil))
            }
        }
        return results
    }

    public func loadPinnedSnapshot(ids: [Int]) async throws -> PinnedSnapshotResult {
        try await fetchPinned(ids: ids, includeUsage: true)
    }

    private func fetchPinned(ids: [Int], includeUsage: Bool) async throws -> PinnedSnapshotResult {
        var seen = Set<Int>()
        let ids = ids.filter { $0 > 0 && seen.insert($0).inserted }
        // No pins means no requests, including no full account-list request.
        guard !ids.isEmpty else { return PinnedSnapshotResult(snapshots: [], accountErrors: [:]) }
        return try await withThrowingTaskGroup(of: (Int, AccountSnapshot?, String?).self) { group in
            var iterator = ids.makeIterator()
            for _ in 0..<4 {
                if let id = iterator.next() { group.addTask { try await self.pinnedSnapshot(id: id, includeUsage: includeUsage) } }
            }
            var snapshots: [Int: AccountSnapshot] = [:]
            var errors: [Int: String] = [:]
            for try await (id, snapshot, error) in group {
                try Task.checkCancellation()
                if let snapshot { snapshots[id] = snapshot }
                if let error { errors[id] = error }
                if let next = iterator.next() { group.addTask { try await self.pinnedSnapshot(id: next, includeUsage: includeUsage) } }
            }
            // Keep the user's pin order, independent of completion order.
            return PinnedSnapshotResult(snapshots: ids.compactMap { snapshots[$0] }, accountErrors: errors)
        }
    }

    private func pinnedSnapshot(id: Int, includeUsage: Bool) async throws -> (Int, AccountSnapshot?, String?) {
        do {
            let account: Account = try await get("accounts/\(id)")
            guard account.id == id else { throw APIError.invalidResponse }
            return (id, includeUsage ? try await snapshot(account) : AccountSnapshot(account: account, usage: nil), nil)
        } catch is CancellationError { throw CancellationError() }
        catch let error as APIError {
            if error == .http(401) || error == .http(403) { throw error }
            let message = error == .http(404) ? "账号不存在或已被删除，可在设置中取消 Pin。" : error.localizedDescription
            return (id, nil, message)
        } catch {
            return (id, nil, "账号读取失败")
        }
    }

    private func snapshot(_ account: Account) async throws -> AccountSnapshot {
        do {
            let passive = account.platform == "anthropic" && ["oauth", "setup-token"].contains(account.type ?? "")
            let usage: UsageInfo = try await get("accounts/\(account.id)/usage", query: [
                URLQueryItem(name: "source", value: passive ? "passive" : "active")
            ])
            return AccountSnapshot(account: account, usage: usage,
                usageError: usage.hasError ? "上游额度暂不可用，请在后台检查账号状态。" : nil)
        } catch is CancellationError { throw CancellationError() }
        catch let error as APIError {
            if error == .http(401) || error == .http(403) { throw error }
            return AccountSnapshot(account: account, usage: nil, usageError: error.localizedDescription)
        } catch {
            return AccountSnapshot(account: account, usage: nil, usageError: "额度读取失败")
        }
    }
}
