import SwiftUI
import Sub2BarCore

/// A separate view dependency boundary keeps account navigation/height changes
/// from rebuilding all-account aggregates. Each metric is evaluated once per body.
struct DashboardMetricsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        let concurrency = store.concurrencySummary
        let estimate = store.estimateSummary
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                actualCostSummary(title: "今日实际消费", icon: "sun.max", today: true)
                    .help("与周期汇总使用相同的已 Pin 且订阅配置完整的 OAuth 账号，按统计时区今日零点起计算实际用户扣费（含倍率），沿用 Admin 开关。统计时区：\(store.configuration.subscriptionTimeZoneID)。")
                actualCostSummary(title: "周期实际消费", icon: "calendar", today: false)
                    .help("各账号按自己的当前订阅周期统计实际用户扣费（含倍率）；斜杠后为同一组账号完整月订阅价之和，不按天摊销。统计时区：\(store.configuration.subscriptionTimeZoneID)。")
            }
            HStack(spacing: 10) {
                summaryCard("总并发", icon: "bolt.horizontal", value: concurrency.value.map { String($0.count) } ?? "—",
                            suffix: concurrency.value?.limit.map { "/ \($0)" } ?? "", isLoading: concurrency.showsLoading,
                            isRefreshing: concurrency.showsRefreshIndicator, failureHelp: concurrency.failureHelp)
                    .help("当前并发 / 并发上限；已读取 \(store.snapshots.count)/\(store.pinCount) 个账号。")
                summaryCard("周额度估算", icon: "chart.bar", value: money(estimate.value), suffix: "", isSensitive: true,
                            isLoading: estimate.showsLoading, isRefreshing: estimate.showsRefreshIndicator,
                            failureHelp: estimate.failureHelp)
                    .help("仅汇总已 Pin 的 OpenAI 账号。本周用量 ÷ 周已用比例，不是余额。覆盖 \(store.estimatedAccounts.count)/\(store.pinCount) 个账号。")
            }
        }
    }
    private func summaryCard(_ title: String, icon: String, value: String, suffix: String,
                             isSensitive: Bool = false, isLoading: Bool = false,
                             isRefreshing: Bool = false, failureHelp: String? = nil) -> some View {
        DashboardSummaryCard(title: title, icon: icon, isRefreshing: isRefreshing, failureHelp: failureHelp) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Group {
                    if isLoading { ProgressView().controlSize(.small).accessibilityLabel("\(title)加载中") }
                    else if isSensitive { SensitiveAmountText(value: value, label: title) }
                    else { Text(value) }
                }.font(.system(size: 24, weight: .semibold)).minimumScaleFactor(0.6)
                if !suffix.isEmpty {
                    Text(suffix).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                }
            }.lineLimit(1).monospacedDigit()
        }
    }
    private func actualCostSummary(title: String, icon: String, today: Bool) -> some View {
        let state = store.actualCostSummary(today: today)
        return ActualCostMetric(title: title, value: state.value?.amount,
            currency: store.configuration.actualCostCurrency,
            isConfigured: !store.eligibleSubscriptionIDs.isEmpty,
            isRefreshing: state.isRefreshing, icon: icon,
            cost: today ? nil : subscriptionMoney(state.value?.subscriptionCost ?? store.totalSubscriptionCost,
                                                  unit: store.configuration.subscriptionCostCurrency),
            failureHelp: state.failureHelp)
    }
}
