import Foundation
import Sub2BarCore

/// A cache key describes the data being counted, never the selected account page.
struct DashboardMetricScope: Equatable {
    var connection: UUID
    var accountIDs: [Int]
    var subscriptions: [Int: AccountSubscription] = [:]
    var cycles: [SubscriptionCycle] = []
    var day: String? = nil
    var includesAdmin = false
    var timeZoneID: String? = nil
}

struct DashboardMetricCache<Value> {
    private var scope: DashboardMetricScope?
    private var value: Value?

    func value(in scope: DashboardMetricScope) -> Value? {
        self.scope == scope ? value : nil
    }

    mutating func record(_ value: Value?, in scope: DashboardMetricScope, failed: Bool) {
        if self.scope != scope { self.scope = scope; self.value = nil }
        // Keep the complete previous aggregate on partial or total failure.
        if !failed { self.value = value }
    }
}

struct DashboardMetricState<Value> {
    let value: Value?
    let isRefreshing: Bool
    let failed: Bool

    var showsLoading: Bool { value == nil && isRefreshing }
    var showsRefreshIndicator: Bool { value != nil && isRefreshing }
    var failureHelp: String? {
        guard failed && !isRefreshing else { return nil }
        return value == nil ? "加载失败，等待重试" : "更新失败，当前显示上次结果"
    }
}

struct DashboardConcurrency: Equatable {
    let count: Int
    let limit: Int?
}

struct DashboardActualCost: Equatable {
    let amount: Decimal
    let subscriptionCost: Decimal?
}
