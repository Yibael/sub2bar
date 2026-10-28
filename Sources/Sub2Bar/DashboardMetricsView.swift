import SwiftUI
import Sub2BarCore

struct DashboardMetricsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var dashboard: GlobalDashboardStore

    init(store: AppStore) { self.store = store; dashboard = store.dashboard }

    var body: some View {
        let concurrency = dashboard.concurrencyState
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                costCard("今日实际消费", icon: "sun.max", metric: .todayActual, unit: store.configuration.actualCostCurrency)
                    .help("全局今日实际用户扣费（含倍率），按统计时区及 Admin 开关计算，包含所有账号类型。")
                costCard("今日标准费用", icon: "chart.bar", metric: .todayStandard, unit: "$")
                    .help("全局今日标准价费用（不含倍率），与实际消费使用相同的时区及 Admin 排除口径。")
            }
            HStack(spacing: 10) {
                costCard("近 30 天消费", icon: "calendar", metric: .thirtyDaysActual, unit: store.configuration.actualCostCurrency)
                    .help("全局近 30 个日历日实际用户扣费：统计时区的今天及之前 29 天，沿用 Admin 开关。")
                DashboardSummaryCard(title: "总并发", icon: "bolt.horizontal",
                    isRefreshing: concurrency.showsRefreshIndicator,
                    failureHelp: dashboard.concurrencyError ?? concurrency.failureHelp) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if concurrency.showsLoading { ProgressView().controlSize(.small).accessibilityLabel("总并发加载中") }
                        else { Text(concurrency.value.map { String($0.count) } ?? "—") }
                        if let limit = concurrency.value?.limit {
                            Text("/ \(limit)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 24, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
                }
                .help(dashboard.concurrencyError ?? "所有账号的当前并发 / 配置并发上限，不受 Pin 或 Admin 消费开关影响。需要服务器启用实时监控。")
            }
        }
    }

    private func costCard(_ title: String, icon: String, metric: GlobalDashboardStore.CostMetric, unit: String) -> some View {
        let state = dashboard.cost(metric)
        return ActualCostMetric(title: title, value: state.value, currency: unit, isConfigured: true,
                                isRefreshing: state.isRefreshing, icon: icon, failureHelp: state.failureHelp)
    }
}
