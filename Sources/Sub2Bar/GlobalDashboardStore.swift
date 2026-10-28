import Foundation
import Combine
import Sub2BarCore

/// Global summaries have their own scope and lifetime: changing the selected
/// account or its subscription must never change the dashboard's denominator.
@MainActor
final class GlobalDashboardStore: ObservableObject {
    enum CostMetric { case todayActual, todayStandard, thirtyDaysActual }
    @Published private(set) var refreshingCosts = false
    @Published private(set) var refreshingConcurrency = false
    @Published private var actual = DashboardMetricCache<Decimal>()
    @Published private var standard = DashboardMetricCache<Decimal>()
    @Published private var month = DashboardMetricCache<Decimal>()
    @Published private var concurrency = DashboardMetricCache<GlobalConcurrency>()
    @Published private var failedCosts: Set<CostMetric> = []
    @Published private(set) var concurrencyError: String?
    @Published private var accountCosts: [Int: UsageCosts] = [:]
    @Published private var sampleScope: DashboardMetricScope?
    private var failureScope: DashboardMetricScope?
    private var configuration = Configuration()
    private var key: String?
    private var connection = UUID()
    private var costGeneration = UUID()
    private var concurrencyGeneration = UUID()
    private var ids: [Int] = []
    private var active = false
    private var costsTask: Task<Void, Never>?
    private var concurrencyTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var costCompleted: Date?
    private var concurrencyCompleted: Date?
    private var costRetry: Date?
    private var concurrencyRetry: Date?
    private var costFailures = 0
    private var concurrencyFailures = 0
    private let now: () -> Date
    private let automaticallySchedule: Bool
    private let clientFactory: AppStore.ClientFactory
    var authenticationFailed: ((Error) -> Void)?

    init(now: @escaping () -> Date, automaticallySchedule: Bool, clientFactory: @escaping AppStore.ClientFactory) {
        self.now = now; self.automaticallySchedule = automaticallySchedule; self.clientFactory = clientFactory
    }

    private var scope: DashboardMetricScope {
        DashboardMetricScope(connection: connection, accountIDs: [],
            day: StatisticsPeriod(at: now(), timeZoneID: configuration.subscriptionTimeZoneID)?.today,
            includesAdmin: configuration.includeAdminUsage, timeZoneID: configuration.subscriptionTimeZoneID)
    }
    private var concurrencyScope: DashboardMetricScope { DashboardMetricScope(connection: connection, accountIDs: []) }
    var hasLoaded: Bool { concurrency.value(in: concurrencyScope) != nil || actual.value(in: scope) != nil }

    func cost(_ metric: CostMetric) -> DashboardMetricState<Decimal> {
        let cache: DashboardMetricCache<Decimal>
        switch metric { case .todayActual: cache = actual; case .todayStandard: cache = standard; case .thirtyDaysActual: cache = month }
        return DashboardMetricState(value: cache.value(in: scope), isRefreshing: refreshingCosts,
                                    failed: failureScope == scope && failedCosts.contains(metric))
    }
    var concurrencyState: DashboardMetricState<GlobalConcurrency> {
        DashboardMetricState(value: concurrency.value(in: concurrencyScope), isRefreshing: refreshingConcurrency,
                             failed: concurrencyError != nil)
    }
    func costs(for id: Int) -> UsageCosts? { sampleScope == scope ? accountCosts[id] : nil }
    func costFailure(for id: Int, standard: Bool) -> String? {
        guard ids.contains(id), !refreshingCosts, sampleScope == scope else { return nil }
        let amount = standard ? accountCosts[id]?.totalCost : accountCosts[id]?.totalActualCost
        return amount == nil ? "今日费用读取失败" : nil
    }

    func configure(_ config: Configuration, key: String?, ids: [Int], active: Bool, dispatch: Bool = true) {
        let connectionChanged = configuration.serverURL != config.serverURL || self.key != key
        let scopeChanged = connectionChanged || configuration.includeAdminUsage != config.includeAdminUsage ||
            configuration.subscriptionTimeZoneID != config.subscriptionTimeZoneID
        let pinsChanged = Set(self.ids) != Set(ids)
        let wasActive = self.active
        configuration = config; self.key = key; self.ids = ids
        self.active = active && key != nil
        if connectionChanged {
            stop(); connection = UUID(); concurrencyCompleted = nil; concurrencyRetry = nil
            concurrencyFailures = 0; concurrencyError = nil
        }
        if scopeChanged || pinsChanged {
            cancelCosts(); costCompleted = nil
            if scopeChanged {
                costRetry = nil; costFailures = 0; failedCosts = []; failureScope = nil
                accountCosts = [:]; sampleScope = nil
            } else { accountCosts = accountCosts.filter { ids.contains($0.key) } }
        }
        if !self.active { stop(); return }
        if !wasActive { costCompleted = nil; concurrencyCompleted = nil }
        if dispatch { runDue() } else { schedule() }
    }

    func refreshManually() {
        guard active else { return }
        if costsTask == nil { costCompleted = nil; costRetry = nil }
        if concurrencyTask == nil { concurrencyCompleted = nil; concurrencyRetry = nil }
        runDue()
    }
    func stop() {
        cancelCosts(); concurrencyGeneration = UUID()
        concurrencyTask?.cancel(); concurrencyTask = nil; refreshingConcurrency = false
        wakeTask?.cancel(); wakeTask = nil
    }
    private func cancelCosts() {
        costGeneration = UUID(); costsTask?.cancel(); costsTask = nil; refreshingCosts = false
    }
    private var costDeadline: Date {
        max((costCompleted ?? .distantPast).addingTimeInterval(configuration.effectiveStatisticsRefreshInterval), costRetry ?? .distantPast)
    }
    private var concurrencyDeadline: Date {
        max((concurrencyCompleted ?? .distantPast).addingTimeInterval(configuration.effectiveAccountRefreshInterval), concurrencyRetry ?? .distantPast)
    }
    func runDue() {
        guard active, let key else { return }
        if costsTask == nil, costDeadline <= now() { refreshCosts(key: key) }
        if concurrencyTask == nil, concurrencyDeadline <= now() { refreshConcurrency(key: key) }
        schedule()
    }
    private func refreshCosts(key: String) {
        guard let period = StatisticsPeriod(at: now(), timeZoneID: configuration.subscriptionTimeZoneID) else { return }
        let config = configuration, requestedScope = scope, token = costGeneration, requestedIDs = ids
        refreshingCosts = true
        costsTask = Task { [self] in
            defer {
                if token == costGeneration {
                    refreshingCosts = false; costsTask = nil; costCompleted = now()
                    costRetry = costFailures == 0 ? nil : now().addingTimeInterval(min(600,
                        config.effectiveStatisticsRefreshInterval * pow(2, Double(costFailures))))
                    schedule()
                }
            }
            do {
                let result = try await clientFactory(config, key).loadGlobalStatistics(period: period,
                    includeAdmin: config.includeAdminUsage, accountIDs: requestedIDs)
                guard token == costGeneration, !Task.isCancelled else { return }
                guard requestedScope == scope else { return }
                var failed: Set<CostMetric> = []
                if result.today.totalActualCost == nil { failed.insert(.todayActual) }
                if result.today.totalCost == nil { failed.insert(.todayStandard) }
                if result.thirtyDays.totalActualCost == nil { failed.insert(.thirtyDaysActual) }
                actual.record(result.today.totalActualCost, in: scope, failed: failed.contains(.todayActual))
                standard.record(result.today.totalCost, in: scope, failed: failed.contains(.todayStandard))
                month.record(result.thirtyDays.totalActualCost, in: scope, failed: failed.contains(.thirtyDaysActual))
                accountCosts = result.accounts; sampleScope = scope
                failedCosts = failed; failureScope = scope
                let accountFailed = result.accounts.values.contains { $0.totalCost == nil || $0.totalActualCost == nil }
                costFailures = failed.isEmpty && !accountFailed ? 0 : min(costFailures + 1, 5)
            } catch {
                guard token == costGeneration, !Task.isCancelled else { return }
                failedCosts = [.todayActual, .todayStandard, .thirtyDaysActual]; failureScope = requestedScope
                accountCosts = [:]; sampleScope = requestedScope; costFailures = min(costFailures + 1, 5)
                authenticationFailed?(error)
            }
        }
    }
    private func refreshConcurrency(key: String) {
        let config = configuration, token = concurrencyGeneration, requestedScope = concurrencyScope
        refreshingConcurrency = true
        concurrencyTask = Task { [self] in
            defer {
                if token == concurrencyGeneration {
                    refreshingConcurrency = false; concurrencyTask = nil; concurrencyCompleted = now()
                    concurrencyRetry = concurrencyFailures == 0 ? nil : now().addingTimeInterval(min(120,
                        config.effectiveAccountRefreshInterval * pow(2, Double(concurrencyFailures))))
                    schedule()
                }
            }
            do {
                let result = try await clientFactory(config, key).loadGlobalConcurrency()
                guard token == concurrencyGeneration, !Task.isCancelled else { return }
                concurrency.record(result, in: requestedScope, failed: false)
                concurrencyError = nil; concurrencyFailures = 0
            } catch {
                guard token == concurrencyGeneration, !Task.isCancelled else { return }
                concurrencyError = error.localizedDescription; concurrencyFailures = min(concurrencyFailures + 1, 5)
                authenticationFailed?(error)
            }
        }
    }
    private func schedule() {
        wakeTask?.cancel(); wakeTask = nil
        guard active, automaticallySchedule else { return }
        var deadlines: [Date] = []
        if costsTask == nil { deadlines.append(costDeadline) }
        if concurrencyTask == nil { deadlines.append(concurrencyDeadline) }
        guard let next = deadlines.min() else { return }
        wakeTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSince(self.now())))) } catch { return }
            guard !Task.isCancelled else { return }
            self.runDue()
        }
    }
}
