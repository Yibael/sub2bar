import Foundation

public struct StatisticsPeriod: Equatable, Sendable {
    public let today: String
    public let thirtyDaysStart: String
    public let timeZoneID: String

    public init?(at date: Date, timeZoneID: String) {
        guard let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: date)) else { return nil }
        func label(_ value: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: value)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
        today = label(date); thirtyDaysStart = label(start); self.timeZoneID = timeZoneID
    }
}

public struct UsageCosts: Sendable, Equatable, Decodable {
    public let totalCost: Decimal?
    public let totalActualCost: Decimal?

    public init(totalCost: Decimal?, totalActualCost: Decimal?) {
        self.totalCost = totalCost; self.totalActualCost = totalActualCost
    }

    public init(from decoder: Decoder) throws {
        enum Keys: CodingKey { case totalCost, totalActualCost }
        let values = try decoder.container(keyedBy: Keys.self)
        func amount(_ key: Keys) -> Decimal? {
            guard let value = try? values.decode(Decimal.self, forKey: key), !value.isNaN, value >= 0 else { return nil }
            return value
        }
        totalCost = amount(.totalCost); totalActualCost = amount(.totalActualCost)
    }

    func subtracting(_ other: UsageCosts) -> UsageCosts {
        func subtract(_ total: Decimal?, _ excluded: Decimal?) -> Decimal? {
            guard let total, let excluded, total >= excluded else { return nil }
            return total - excluded
        }
        return UsageCosts(totalCost: subtract(totalCost, other.totalCost),
                          totalActualCost: subtract(totalActualCost, other.totalActualCost))
    }
}

public struct GlobalStatistics: Sendable {
    public let today: UsageCosts
    public let thirtyDays: UsageCosts
    public let accounts: [Int: UsageCosts]
}

public struct GlobalConcurrency: Equatable, Sendable {
    public let count: Int
    public let limit: Int
}

extension APIClient {
    /// One Admin directory per refresh; all cost fields use the same filters.
    /// Global requests deliberately omit account_id, including when no accounts are pinned.
    public func loadGlobalStatistics(period: StatisticsPeriod, includeAdmin: Bool, accountIDs: [Int]) async throws -> GlobalStatistics {
        let admins = includeAdmin ? [] : try await loadAdminUserIDs()
        @Sendable func read(start: String, accountID: Int? = nil) async throws -> UsageCosts {
            do {
                var excluded = UsageCosts(totalCost: 0, totalActualCost: 0)
                for id in admins {
                    let costs = try await usageCosts(start: start, period: period, accountID: accountID, userID: id)
                    func sum(_ left: Decimal?, _ right: Decimal?) -> Decimal? {
                        guard let left, let right else { return nil }
                        return left + right
                    }
                    excluded = UsageCosts(totalCost: sum(excluded.totalCost, costs.totalCost),
                                          totalActualCost: sum(excluded.totalActualCost, costs.totalActualCost))
                }
                return try await usageCosts(start: start, period: period, accountID: accountID, userID: nil).subtracting(excluded)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if let error = error as? APIError, error == .http(401) || error == .http(403) { throw error }
                return UsageCosts(totalCost: nil, totalActualCost: nil)
            }
        }
        async let today = read(start: period.today)
        async let month = read(start: period.thirtyDaysStart)
        let ids = Array(Set(accountIDs.filter { $0 > 0 })).sorted()
        let accounts = try await withThrowingTaskGroup(of: (Int, UsageCosts).self) { group in
            var iterator = ids.makeIterator()
            func enqueue(_ id: Int) { group.addTask { (id, try await read(start: period.today, accountID: id)) } }
            for _ in 0..<2 { if let id = iterator.next() { enqueue(id) } }
            var values: [Int: UsageCosts] = [:]
            for try await (id, costs) in group {
                values[id] = costs
                if let next = iterator.next() { enqueue(next) }
            }
            return values
        }
        return try await GlobalStatistics(today: today, thirtyDays: month, accounts: accounts)
    }

    private func usageCosts(start: String, period: StatisticsPeriod, accountID: Int?, userID: Int?) async throws -> UsageCosts {
        var query = [URLQueryItem(name: "start_date", value: start), URLQueryItem(name: "end_date", value: period.today),
                     URLQueryItem(name: "timezone", value: period.timeZoneID), URLQueryItem(name: "nocache", value: "true")]
        if let accountID { query.append(URLQueryItem(name: "account_id", value: String(accountID))) }
        if let userID { query.append(URLQueryItem(name: "user_id", value: String(userID))) }
        return try await get("usage/stats", query: query)
    }

    public func loadGlobalConcurrency() async throws -> GlobalConcurrency {
        struct Item: Decodable { let currentInUse: Int; let maxCapacity: Int }
        struct Payload: Decodable { let enabled: Bool; let account: [String: Item] }
        let result: Payload = try await get("ops/concurrency")
        guard result.enabled else { throw APIError.monitoringUnavailable }
        var count = 0, limit = 0
        for item in result.account.values {
            let nextCount = count.addingReportingOverflow(item.currentInUse)
            let nextLimit = limit.addingReportingOverflow(item.maxCapacity)
            guard item.currentInUse >= 0, item.maxCapacity >= 0, !nextCount.overflow, !nextLimit.overflow else {
                throw APIError.invalidResponse
            }
            count = nextCount.partialValue; limit = nextLimit.partialValue
        }
        return GlobalConcurrency(count: count, limit: limit)
    }
}
