import Foundation

extension APIClient {
    /// Aggregate user-billed actual_cost, not account cost or standard price.
    /// All endpoints in this path query sub2api's database; never /accounts/:id/usage.
    public func loadSubscriptionUsage(_ requests: [SubscriptionUsageRequest], includeAdmin: Bool,
                                      at date: Date) async throws -> [SubscriptionUsageResult] {
        guard !requests.isEmpty else { return [] }
        var seen = Set<Int>()
        guard requests.allSatisfy({ $0.accountID > 0 && seen.insert($0.accountID).inserted &&
            $0.cycle.start <= date && date < $0.cycle.end }) else { throw SubscriptionError.invalidConfiguration }
        let adminIDs = includeAdmin ? [] : try await loadAdminUserIDs()
        return try await withThrowingTaskGroup(of: SubscriptionUsageResult.self) { group in
            var iterator = requests.makeIterator()
            func enqueue(_ request: SubscriptionUsageRequest) {
                group.addTask {
                    do {
                        // Read the admin subtotals first, then the total. These
                        // are near-real-time aggregates, not an atomic snapshot.
                        var excluded = Decimal.zero
                        for id in adminIDs {
                            excluded += try await self.subscriptionActualCost(request, userID: id, at: date)
                        }
                        let total = try await self.subscriptionActualCost(request, userID: nil, at: date)
                        guard !excluded.isNaN, total >= excluded else { throw SubscriptionError.invalidStatistics }
                        return SubscriptionUsageResult(request: request, actualCost: total - excluded, error: nil)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if let error = error as? APIError, error == .http(401) || error == .http(403) { throw error }
                        return SubscriptionUsageResult(request: request, actualCost: nil, error: "订阅消费读取失败")
                    }
                }
            }
            for _ in 0..<4 { if let request = iterator.next() { enqueue(request) } }
            var results: [Int: SubscriptionUsageResult] = [:]
            for try await result in group {
                try Task.checkCancellation()
                results[result.request.accountID] = result
                if let request = iterator.next() { enqueue(request) }
            }
            return requests.compactMap { results[$0.accountID] }
        }
    }

    private func subscriptionActualCost(_ request: SubscriptionUsageRequest, userID: Int?, at date: Date) async throws -> Decimal {
        struct Stats: Decodable { let totalActualCost: Decimal }
        var query = [URLQueryItem(name: "account_id", value: String(request.accountID)),
                     URLQueryItem(name: "start_date", value: request.cycle.dateString(request.cycle.start)),
                     URLQueryItem(name: "end_date", value: request.cycle.dateString(min(date, request.cycle.lastIncludedDate))),
                     URLQueryItem(name: "timezone", value: request.cycle.timeZoneID),
                     URLQueryItem(name: "nocache", value: "true")]
        if let userID { query.append(URLQueryItem(name: "user_id", value: String(userID))) }
        let stats: Stats = try await get("usage/stats", query: query)
        guard !stats.totalActualCost.isNaN, stats.totalActualCost >= 0 else { throw SubscriptionError.invalidStatistics }
        return stats.totalActualCost
    }

    private func loadAdminUserIDs() async throws -> [Int] {
        struct User: Decodable { let id: Int; let role: String }
        struct Page: Decodable { let items: [User]; let total: Int }
        var ids: [Int] = []; var seen = Set<Int>()
        for index in 1...100 {
            let page: Page = try await get("users", query: [URLQueryItem(name: "role", value: "admin"),
                URLQueryItem(name: "page", value: String(index)), URLQueryItem(name: "page_size", value: "100")])
            guard page.total >= 0, page.items.allSatisfy({ $0.id > 0 && $0.role == "admin" }) else {
                throw SubscriptionError.invalidAdminList
            }
            let new = page.items.filter { seen.insert($0.id).inserted }
            ids.append(contentsOf: new.map(\.id))
            if ids.count >= page.total { return ids }
            guard !new.isEmpty else { throw SubscriptionError.invalidAdminList }
        }
        throw SubscriptionError.invalidAdminList
    }
}
