import SwiftUI
import Sub2BarCore

struct LocalQuotaSection: View {
    let quotas: [AccountQuota]
    var unavailable = false
    var date = Date()
    var body: some View {
        if quotas.isEmpty {
            Text(unavailable ? "限额信息暂不可用" : "未配置 sub2api 限额")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: PanelSizing.emptyQuotaHeight, alignment: .leading)
        } else {
            VStack(spacing: PanelSizing.quotaRowSpacing) {
                ForEach(quotas) { quota in
                    QuotaProgressLine(title: quota.title, percentage: quota.percentage,
                                      resetCountdown: quota.resetDate.map { ResetCountdown.text(until: $0, at: date) })
                        .help("sub2api 配置的\(quota.title)，不是上游余额。已用金额和上限可在展开详情中查看。")
                }
            }
        }
    }
}

/// Shared geometry and styling, not shared quota semantics or row positions.
struct QuotaProgressLine: View {
    let title: String
    let percentage: Double?
    var resetCountdown: String? = nil
    var isLoading = false
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.075))
                    if let percentage {
                        Capsule().fill(Theme.usageColor(percentage)).frame(width: geo.size.width * min(1, max(0, percentage / 100)))
                    }
                }
            }.frame(height: 4)
            Group {
                if percentage == nil && isLoading { ProgressView().controlSize(.mini) }
                else { Text(percentage.map { String(format: "%.1f%%", $0) } ?? "—") }
            }
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(Theme.usageColor(percentage)).frame(width: 47, height: 12, alignment: .trailing)
            if let resetCountdown {
                Label(resetCountdown, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize().frame(width: 82, alignment: .leading)
                    .help("\(title)重置：\(resetCountdown)")
            }
        }
        .frame(height: PanelSizing.quotaRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)已用 \(percentage.map { String(format: "%.1f%%", $0) } ?? "未知")\(resetCountdown.map { "，重置 \($0)" } ?? "")")
    }
}
