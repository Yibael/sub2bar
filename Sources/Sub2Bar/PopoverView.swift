import SwiftUI
import Sub2BarCore

enum Theme {
    static let accent = Color.primary
    static func usageColor(_ value: Double?) -> Color {
        value == nil ? .secondary : .primary
    }
}

struct PopoverView: View {
    @ObservedObject var store: AppStore
    let openSettings: () -> Void
    let version: String
    let onHeightChange: (CGFloat) -> Void
    @State private var measurements: [PanelSection: CGFloat] = [:]

    init(store: AppStore, openSettings: @escaping () -> Void,
         version: String = AppVersion.display(in: Bundle.main.infoDictionary),
         onHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.store = store
        self.openSettings = openSettings
        self.version = version
        self.onHeightChange = onHeightChange
    }

    private var hasDashboard: Bool { store.isConfigured && !store.needsCredentialAccess && store.pinCount > 0 }
    private var panelHeight: CGFloat { PanelSizing.height(measurements: measurements, hasDashboard: hasDashboard) }
    private var canReportHeight: Bool { !hasDashboard || PanelSizing.hasMeasurements(measurements) }

    var body: some View {
        VStack(spacing: 0) {
            header.measurePanelSection(.header)
            if !store.isConfigured { welcome }
            else if store.needsCredentialAccess { credentialRequired }
            else if store.pinCount == 0 { noPins }
            else { dashboard }
            footer.measurePanelSection(.footer)
        }
        .frame(width: PanelSizing.width)
        .frame(height: hasDashboard ? nil : PanelSizing.placeholderHeight)
        .fixedSize(horizontal: false, vertical: true)
        // NSPopover supplies one continuous material for the body and its arrow.
        .tint(Theme.accent)
        .environment(\.isMenuPanelSurface, true)
        .environment(\.sensitiveAmountsHidden, store.areAmountsHidden)
        .onPreferenceChange(PanelMeasurements.self) { value in
            if measurements != value { measurements = value }
        }
        .onChange(of: panelHeight) { _, height in if canReportHeight { onHeightChange(height) } }
        .onAppear { if canReportHeight { onHeightChange(panelHeight) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 32, height: 32).insetSurface(cornerRadius: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text("Sub2Bar").font(.system(size: 15, weight: .semibold))
                Text(store.hostLabel)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            refreshStatus
            QuotaRefreshButton(isLoading: store.showsQuotaLoading || store.isLoadingInitialAccounts,
                               isEnabled: !store.needsCredentialAccess && store.isPanelVisible && store.isConfigured && store.pinCount > 0,
                               action: store.refreshManually)
        }
        .padding(.horizontal, 20).padding(.vertical, 17)
    }

    private var refreshStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            QuotaRefreshStatus(text: store.quotaRefreshLabel(at: context.date))
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                .frame(width: 64, height: 64).insetSurface(cornerRadius: 12)
            VStack(spacing: 8) {
                Text("未配置服务器").font(.system(size: 20, weight: .semibold))
                Text("在设置中填写 URL 和 Admin Key。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            Button("配置服务器", action: openSettings).buttonStyle(NeutralButtonStyle(.primary))
            Spacer()
            Label("配置保存在当前 Mac", systemImage: "desktopcomputer")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var credentialRequired: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(store.isLoadingCredential ? "正在读取设置" : "请设置 Admin Key").font(.system(size: 20, weight: .semibold))
            Text(store.credentialError ?? "在设置中输入密钥，保存后自动使用。")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 30)
            Button("打开设置", action: openSettings).buttonStyle(NeutralButtonStyle(.primary))
            Spacer()
            Text("未配置密钥时不发请求")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dashboard: some View {
        VStack(spacing: 12) {
            dashboardHeader.measurePanelSection(.dashboard)
            selectedAccount.fixedSize(horizontal: false, vertical: true).measurePanelSection(.accounts)
        }.padding(.horizontal, 18).padding(.bottom, 12).fixedSize(horizontal: false, vertical: true)
    }

    private var dashboardHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                todayActualSummary
                subscriptionSummary
            }
            HStack(spacing: 10) {
                summaryCard("总并发", icon: "bolt.horizontal", value: store.concurrency.map(String.init) ?? "—",
                            suffix: store.concurrencyLimit.map { "/ \($0)" } ?? "", isLoading: store.isLoadingInitialAccounts)
                    .help("当前并发 / 并发上限；已读取 \(store.snapshots.count)/\(store.pinCount) 个账号。")
                summaryCard("周额度估算", icon: "chart.bar", value: money(store.estimatedTotal), suffix: "", isSensitive: true,
                            isLoading: store.estimatedTotal == nil && (store.isLoadingInitialAccounts ||
                                (store.isRefreshingQuota && store.snapshots.allSatisfy { $0.statisticsUsage == nil })))
                    .help("仅汇总已 Pin 的 OpenAI 账号。本周用量 ÷ 周已用比例，不是余额。覆盖 \(store.estimatedAccounts.count)/\(store.pinCount) 个账号。")
            }
            if let error = store.errorMessage {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error + (store.lastUpdated == nil ? "" : " 显示上次结果。"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).insetSurface(cornerRadius: 8)
            }
            HStack(spacing: 10) {
                AccountListSummary(overview: store.accountOverview)
                if store.pinCount > 1 { accountNavigation }
            }
        }
    }

    @ViewBuilder
    private var selectedAccount: some View {
        if let id = store.selectedPinnedID, let error = store.pinnedAccountErrors[id] {
            VStack(alignment: .leading, spacing: 8) {
                Label("账号 #\(id) 加载失败", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .medium))
                Text(error)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
                .frame(minHeight: PanelSizing.accountCardHeight, alignment: .topLeading).insetSurface(cornerRadius: 9)
        } else if let snapshot = store.selectedPinnedSnapshot {
            AccountCard(snapshot: snapshot, stale: store.errorMessage != nil,
                        isPanelVisible: store.isPanelVisible,
                        todayCost: store.todayUsage[snapshot.id],
                        todayUsageError: store.todayUsageErrors[snapshot.id],
                        subscription: store.subscriptions[snapshot.id],
                        subscriptionCycle: store.subscriptionCycle(for: snapshot.id),
                        subscriptionSample: store.subscriptionSample(for: snapshot.id),
                        subscriptionError: store.subscriptionErrors[snapshot.id],
                        actualCostCurrency: store.configuration.actualCostCurrency,
                        subscriptionCostCurrency: store.configuration.subscriptionCostCurrency,
                        isRefreshingTodayUsage: store.isRefreshing,
                        isRefreshingQuota: store.isRefreshingQuota,
                        isRefreshingSubscription: store.isRefreshingSubscriptions,
                        onSwitchAccount: store.selectAdjacentPinned)
                .id(snapshot.id)
        } else {
            AccountLoadingPlaceholder(isLoading: store.isLoadingInitialAccounts || store.isRefreshing)
        }
    }

    private var accountNavigation: some View {
        HStack(spacing: 3) {
            Button { store.selectAdjacentPinned(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("上一个 Pin 账号").accessibilityLabel("上一个 Pin 账号")
            Text("\((store.selectedPinnedIndex ?? 0) + 1) / \(store.pinCount)")
                .font(.system(size: 10, weight: .medium)).monospacedDigit().fixedSize()
                .accessibilityLabel("第 \((store.selectedPinnedIndex ?? 0) + 1) 个，共 \(store.pinCount) 个 Pin 账号")
            Button { store.selectAdjacentPinned(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("下一个 Pin 账号").accessibilityLabel("下一个 Pin 账号")
        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
    }

    private func summaryCard(_ title: String, icon: String, value: String, suffix: String,
                             isSensitive: Bool = false, isLoading: Bool = false) -> some View {
        DashboardSummaryCard(title: title, icon: icon) {
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

    private var todayActualSummary: some View {
        actualCostSummary(title: "今日实际消费", icon: "sun.max", value: store.totalTodayActualCost)
            .help("与周期汇总使用相同的已 Pin 且订阅配置完整的 OAuth 账号，按统计时区今日零点起计算实际用户扣费（含倍率），沿用 Admin 开关。统计时区：\(store.configuration.subscriptionTimeZoneID)。")
    }

    private var subscriptionSummary: some View {
        actualCostSummary(title: "周期实际消费", icon: "calendar", value: store.totalSubscriptionActualCost,
                          cost: subscriptionMoney(store.totalSubscriptionCost, unit: store.configuration.subscriptionCostCurrency))
            .help("各账号按自己的当前订阅周期统计实际用户扣费（含倍率）；斜杠后为同一组账号完整月订阅价之和，不按天摊销。统计时区：\(store.configuration.subscriptionTimeZoneID)。")
    }

    private func actualCostSummary(title: String, icon: String, value: Decimal?, cost: String? = nil) -> some View {
        ActualCostMetric(title: title, value: value,
            currency: store.configuration.actualCostCurrency,
            isConfigured: !store.eligibleSubscriptionIDs.isEmpty,
            isRefreshing: store.isRefreshingSubscriptions || store.isLoadingInitialAccounts, icon: icon, cost: cost)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: store.connectionState.symbol)
                            .font(.system(size: 9))
                        Text(store.connectionState.rawValue).font(.system(size: 10))
                    }
                    VersionBadge(version: version)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                Spacer()
                Button { store.openDashboard() } label: { Image(systemName: "arrow.up.right.square") }
                    .disabled(!store.isConfigured).help("打开 sub2api 后台").accessibilityLabel("打开 sub2api 后台")
                AmountVisibilityButton(isHidden: store.areAmountsHidden, action: store.toggleAmountVisibility)
                Button(action: openSettings) { Image(systemName: "gearshape") }.help("设置…").accessibilityLabel("设置")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                    .help("退出 Sub2Bar").accessibilityLabel("退出 Sub2Bar")
            }
            .buttonStyle(NeutralButtonStyle(.ghost, compact: true)).font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 13)
        }
    }

    private var noPins: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "pin.slash").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text("未选择账号").font(.system(size: 20, weight: .semibold))
            Text("在设置中 Pin 账号。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            Button("选择账号", action: openSettings).buttonStyle(NeutralButtonStyle(.primary))
            Spacer()
            Text("0 个账号")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DashboardSummaryCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 12).accessibilityHidden(true)
                Text(title)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .lineLimit(1).frame(height: 14, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 10))
        .insetSurface(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }
}

struct ActualCostMetric: View {
    let title: String
    let value: Decimal?
    let currency: String
    let isConfigured: Bool
    let isRefreshing: Bool
    var icon: String = "calendar"
    var cost: String? = nil

    var showsLoading: Bool { isConfigured && value == nil && isRefreshing }

    var body: some View {
        DashboardSummaryCard(title: title, icon: icon) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if showsLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("统计数据加载中")
                } else if !isConfigured {
                    Text("未配置订阅").font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    SensitiveAmountText(value: subscriptionMoney(value, unit: currency), label: title)
                        .font(.system(size: 24, weight: .semibold)).minimumScaleFactor(0.55)
                }
                if let cost {
                    SensitiveAmountText(value: cost, prefix: "/ ", label: "订阅成本")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .minimumScaleFactor(0.75)
                        .help("订阅成本")
                }
            }
            .monospacedDigit().lineLimit(1)
        }
    }
}

struct AccountListSummary: View {
    let overview: PinnedAccountOverview

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title.fixedSize()
                Spacer(minLength: 0)
                details.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                title
                details
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var title: some View { Text("已 Pin \(overview.total) 个账号") }

    private var details: some View {
        HStack(spacing: 8) {
            if !overview.statusText.isEmpty {
                Text(overview.statusText).fixedSize(horizontal: false, vertical: true)
            }
            if overview.attention > 0 {
                Label("需关注 \(overview.attention)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.primary).fixedSize()
                    .help("存在不可调度、额度接近上限或额度读取失败的账号。")
            }
        }
    }
}

struct VersionBadge: View {
    let version: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(version)
            .font(.system(size: 9, weight: .medium)).monospacedDigit()
            .foregroundStyle(.secondary).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).frame(height: 18)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.12), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .help("版本 \(version)")
            .accessibilityLabel("版本 \(version)")
    }
}

struct QuotaRefreshStatus: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "timer")
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .lineLimit(1).foregroundStyle(.primary)
            .frame(width: 124, height: 20, alignment: .trailing)
            .transaction { $0.animation = nil }
    }
}

struct QuotaRefreshButton: View {
    let isLoading: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.75)
                    .frame(width: 20, height: 20).padding(6)
                    .help("额度刷新中").accessibilityLabel("额度刷新中")
            } else {
                Button(action: action) {
                    Image(systemName: "arrow.clockwise").resizable().scaledToFit()
                        .frame(width: 12, height: 12)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(NeutralButtonStyle(.ghost, compact: true))
                .disabled(!isEnabled)
                .help("立即刷新").accessibilityLabel("立即刷新")
            }
        }
        .frame(width: 32, height: 32)
        .transaction { $0.animation = nil }
    }
}

struct AccountLoadingPlaceholder: View {
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.regular).accessibilityLabel("账号加载中")
            } else {
                Text("账号尚未载入").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PanelSizing.accountCardHeight)
        .insetSurface(cornerRadius: 9)
    }
}

struct AccountCard: View {
    let snapshot: AccountSnapshot
    let stale: Bool
    let isPanelVisible: Bool
    var todayCost: Double? = nil
    var todayUsageError: String? = nil
    var subscription: AccountSubscription? = nil
    var subscriptionCycle: SubscriptionCycle? = nil
    var subscriptionSample: SubscriptionUsageSample? = nil
    var subscriptionError: String? = nil
    var actualCostCurrency = "$"
    var subscriptionCostCurrency = "$"
    var isRefreshingTodayUsage = false
    var isRefreshingQuota = false
    var isRefreshingSubscription = false
    var onSwitchAccount: ((Int) -> Void)? = nil
    @State var expanded = false
    private var account: Account { snapshot.account }
    var showsSubscriptionLoading: Bool {
        subscription?.isComplete == true && subscriptionSample == nil && subscriptionError == nil && isRefreshingSubscription
    }
    private var awaitsQuota: Bool {
        isRefreshingQuota && snapshot.statisticsUsage == nil && snapshot.usage == nil && snapshot.usageError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 9) {
                    ProviderIcon(platform: account.platform)
                        .frame(width: 28, height: 28).insetSurface(cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("\(account.platformLabel) · \(account.stateLabel(at: Date()))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("并发").font(.system(size: 9)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(account.currentConcurrency.map(String.init) ?? "—")
                                .font(.system(size: 19, weight: .semibold))
                            Text("/ \(account.concurrency.map(String.init) ?? "—")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("并发 \(account.currentConcurrency.map(String.init) ?? "未知")，上限 \(account.concurrency.map(String.init) ?? "未知")")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(expanded ? "收起账号详情" : "展开账号详情")

            if isPanelVisible {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    quotaLines(at: context.date)
                }
            } else {
                quotaLines(at: .now)
            }
            HStack(spacing: 12) {
                usageMetric("今日用量", todayCost, alignment: .leading,
                            isLoading: todayCost == nil && todayUsageError == nil && isRefreshingTodayUsage)
                    .help("按标准价格折算，不含倍率；从服务端时区今日 00:00 起，仅统计本实例记录的用量。")
                Divider().frame(height: 28)
                usageMetric("本周用量", snapshot.weeklyCost, alignment: .leading, isLoading: awaitsQuota)
                    .help("7 天额度重置窗口内的账号口径费用，包含账号倍率，不是自然周。")
                Divider().frame(height: 28)
                usageMetric("周额度估算", snapshot.estimatedWeeklyCost, alignment: .leading,
                            isLoading: awaitsQuota && account.platform == "openai")
            }.padding(.vertical, 4)

            if account.supportsSubscription {
                if subscription?.isComplete == true {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            textMetric("周期消费", subscriptionMoney(subscriptionSample?.actualCost, unit: actualCostCurrency),
                                       isSensitive: true, isLoading: showsSubscriptionLoading)
                                .help("当前订阅周期实际扣费（含倍率）")
                            Divider().frame(height: 28)
                            textMetric("订阅成本", subscriptionMoney(subscription?.monthlyPrice, unit: subscriptionCostCurrency), isSensitive: true)
                            Divider().frame(height: 28)
                            textMetric("周期", subscriptionCycle?.shortLabel ?? "—")
                                .help(subscriptionCycle?.label ?? "周期不可用")
                        }
                        if let subscriptionError {
                            Text(subscriptionError).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("订阅未配置完整 · 不纳入消费与成本汇总")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            if let todayUsageError {
                Label(todayUsageError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            if snapshot.usageError != nil {
                Label("额度读取失败", systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.primary)
            } else if (snapshot.weeklyPercentage ?? 0) >= 90 || (snapshot.usage?.fiveHour?.percentage ?? 0) >= 90 {
                Label("额度接近上限", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.primary)
            }
            if expanded { details }
        }
        .padding(13)
        .frame(minHeight: PanelSizing.accountCardHeight, alignment: .topLeading)
        .insetSurface(cornerRadius: 9)
        .opacity(stale ? 0.65 : 1)
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            // Expanded detail text remains selectable without accidental paging.
            guard !expanded, abs(value.translation.width) > 50,
                  abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
            onSwitchAccount?(value.translation.width < 0 ? 1 : -1)
        })
    }

    private func usageMetric(_ title: String, _ value: Double?, alignment: HorizontalAlignment, isLoading: Bool = false) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Group {
                if isLoading { ProgressView().controlSize(.mini).accessibilityLabel("\(title)加载中") }
                else { SensitiveAmountText(value: money(value), label: title) }
            }.font(.system(size: 12, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(height: 16)
        }.frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    private func textMetric(_ title: String, _ value: String, isSensitive: Bool = false, isLoading: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Group {
                if isLoading { ProgressView().controlSize(.mini).accessibilityLabel("\(title)加载中") }
                else if isSensitive { SensitiveAmountText(value: value, label: title) }
                else { Text(value) }
            }.font(.system(size: 12, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(height: 16)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaLines(at date: Date) -> some View {
        VStack(spacing: 11) {
            usageLine(title: "5 小时", percentage: snapshot.usage?.fiveHour?.percentage,
                      resetCountdown: ResetCountdown.text(until: snapshot.usage?.fiveHour?.resetDate, at: date))
            usageLine(title: "7 天", percentage: snapshot.weeklyPercentage,
                      resetCountdown: ResetCountdown.text(until: snapshot.usage?.sevenDay?.resetDate, at: date))
        }
    }

    private func usageLine(title: String, percentage: Double?, resetCountdown: String? = nil) -> some View {
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
                if percentage == nil && awaitsQuota {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(percentage.map { String(format: "%.1f%%", $0) } ?? "—")
                }
            }
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.usageColor(percentage)).frame(width: 47, height: 12, alignment: .trailing)
            if let resetCountdown {
                Label(resetCountdown, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize().frame(width: 82, alignment: .leading)
                    .help("\(title)额度重置：\(resetCountdown)")
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title)已用 \(percentage.map { String(format: "%.1f%%", $0) } ?? "未知")\(resetCountdown.map { "，重置 \($0)" } ?? "")")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            detail("账号 ID", "#\(account.id)")
            detail("类型", account.type ?? "—")
            detail("5 小时重置", resetText(snapshot.usage?.fiveHour))
            detail("7 天重置", resetText(snapshot.usage?.sevenDay))
            detail("今日用量（标准价）", money(todayCost), isSensitive: true)
            detail("本周用量", money(snapshot.weeklyCost), isSensitive: true)
            if let subscriptionCycle { detail("订阅周期（含首尾）", subscriptionCycle.label) }
            if let subscriptionSample {
                detail("本周期消费采样", subscriptionSample.sampledAt.formatted(date: .abbreviated, time: .shortened))
                detail("消费口径", subscriptionSample.includesAdmin ? "实际扣费 · 含 Admin" : "实际扣费 · 不含 Admin")
                detail("周期时区", subscriptionSample.cycle.timeZoneID)
            }
            if let updated = snapshot.statisticsUpdatedAt {
                detail("计费统计采样", updated.formatted(date: .omitted, time: .standard))
            }
            detail("RPM / 活跃会话", "\(account.currentRpm.map(String.init) ?? "—") / \(account.activeSessions.map(String.init) ?? "—")")
            if let limit = account.quotaWeeklyLimit, limit > 0 { detail("配置的周限额", money(limit), isSensitive: true) }
            if let usage = snapshot.usage {
                if let value = usage.sevenDaySonnet?.percentage { usageLine(title: "Sonnet", percentage: value) }
                if let value = usage.geminiSharedDaily?.percentage { usageLine(title: "日共享", percentage: value) }
                if let value = usage.geminiProDaily?.percentage { usageLine(title: "Pro 日", percentage: value) }
                if let value = usage.geminiFlashDaily?.percentage { usageLine(title: "Flash 日", percentage: value) }
                detail("额度采样", usage.updatedAt.flatMap(parseAPIDate).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "上游未提供时间")
            }
            if let error = snapshot.usageError {
                Text(error).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 10))
    }
    private func detail(_ title: String, _ value: String, isSensitive: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Group {
                if isSensitive { SensitiveAmountText(value: value, label: title) }
                else { Text(value) }
            }.textSelection(.enabled)
        }
    }
    private func resetText(_ window: UsageWindow?) -> String {
        guard let date = window?.resetDate else { return "未知" }
        if date <= Date() { return "等待新采样" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

func money(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
}

func subscriptionMoney(_ value: Decimal?, unit: String = "$") -> String {
    CurrencyUnit.format(value, unit: unit)
}
