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
            DashboardMetricsView(store: store)
            HStack(spacing: 10) {
                AccountListSummary(overview: store.accountOverview, warningHelp: store.accountWarningHelp)
                if store.pinCount > 1 { accountNavigation }
            }
        }
    }

    private var selectedAccount: some View {
        PinnedAccountPage(store: store, navigation: store.navigation)
    }

    private var accountNavigation: some View {
        PinnedAccountNavigationControls(store: store, navigation: store.navigation)
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
    var isRefreshing = false
    var failureHelp: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 12).accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 2)
                DashboardRefreshIndicator(title: title, isRefreshing: isRefreshing, failureHelp: failureHelp)
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

/// Delaying only the corner indicator avoids flashes without delaying data or
/// extending the spinner after completion. Its slot never changes card layout.
struct DashboardRefreshIndicator: View {
    let title: String
    let isRefreshing: Bool
    let failureHelp: String?
    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            if isRefreshing && showsSpinner {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("\(title)更新中")
                    .help("正在更新，当前显示上次结果")
            } else if !isRefreshing, let failureHelp {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .help(failureHelp)
                    .accessibilityLabel("\(title)：\(failureHelp)")
            }
        }
        .frame(width: 12, height: 12)
        .task(id: isRefreshing) {
            showsSpinner = false
            guard isRefreshing else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            showsSpinner = true
        }
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
    var failureHelp: String? = nil

    var showsLoading: Bool { isConfigured && value == nil && isRefreshing }
    var showsRefreshIndicator: Bool { isConfigured && value != nil && isRefreshing }

    var body: some View {
        DashboardSummaryCard(title: title, icon: icon, isRefreshing: showsRefreshIndicator, failureHelp: failureHelp) {
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
    var warningHelp: String? = nil

    var effectiveWarningHelp: String? {
        if let warningHelp { return warningHelp }
        if overview.failed > 0 { return "\(overview.failed) 个账号详情读取失败，缓存数据非实时。" }
        if overview.attention > 0 { return "存在不可调度或额度接近上限的账号。" }
        return nil
    }

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

    private var title: some View {
        HStack(spacing: 6) {
            Text("已 Pin \(overview.total) 个账号")
            FieldFailureIndicator(message: effectiveWarningHelp, label: "账号提示", symbol: "exclamationmark.triangle")
        }
    }

    private var details: some View {
        HStack(spacing: 8) {
            if !overview.informationalStatusText.isEmpty {
                Text(overview.informationalStatusText).fixedSize(horizontal: false, vertical: true)
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
    var accountID: Int? = nil

    var body: some View {
        VStack(spacing: 10) {
            if let accountID { Text("账号 #\(accountID)").font(.system(size: 12, weight: .medium)) }
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
    var todayStats: AccountTodayStats? = nil
    var todayUsageError: String? = nil
    var accountReadError: String? = nil
    var accountUpdatedAt: Date? = nil
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
        account.supportsUsageQuery && isRefreshingQuota && snapshot.statisticsUsage == nil && snapshot.usage == nil && snapshot.usageError == nil
    }
    private func dailyFailure(_ field: DailyAccountField) -> String? {
        field.failure(in: todayStats, standardCost: todayCost, error: todayUsageError)
    }
    private var quotaFailure: String? {
        guard account.supportsUsageQuery, let error = snapshot.usageError else { return nil }
        return error + (snapshot.usage == nil ? "" : " · 当前显示上次数据")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 9) {
                    ProviderIcon(platform: account.platform)
                        .frame(width: 28, height: 28).insetSurface(cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("\(account.platformLabel) · \(account.typeLabel) · \(stale ? "状态待更新" : account.stateLabel(at: Date()))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("并发").font(.system(size: 9)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(stale ? "—" : (account.currentConcurrency.map(String.init) ?? "—"))
                                .font(.system(size: 19, weight: .semibold))
                            Text("/ \(account.concurrency.map(String.init) ?? "—")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("并发 \(stale ? "未知" : (account.currentConcurrency.map(String.init) ?? "未知"))，上限 \(account.concurrency.map(String.init) ?? "未知")")
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
                            isLoading: todayCost == nil && todayUsageError == nil && isRefreshingTodayUsage,
                            failureHelp: dailyFailure(.standardCost))
                    .help(dailyFailure(.standardCost) ?? "按标准价格折算，不含倍率；从服务端时区今日 00:00 起，仅统计本实例记录的用量。")
                Divider().frame(height: 28)
                if account.isAPIKeyAccount {
                    usageMetric("今日账号费用", todayStats?.accountCost, alignment: .leading,
                                isLoading: todayStats == nil && todayUsageError == nil && isRefreshingTodayUsage,
                                failureHelp: dailyFailure(.accountCost))
                        .help(dailyFailure(.accountCost) ?? "sub2api 记录的今日账号口径费用，包含账号倍率及统计价格调整，不是上游对账账单。")
                    Divider().frame(height: 28)
                    textMetric("今日请求", todayStats?.requests.map { $0.formatted() } ?? "—",
                               isLoading: todayStats == nil && todayUsageError == nil && isRefreshingTodayUsage,
                               failureHelp: dailyFailure(.requests))
                        .help(dailyFailure(.requests) ?? "服务端时区今日零点起，本实例记录的请求数。")
                } else {
                    usageMetric("本周用量", snapshot.weeklyCost, alignment: .leading, isLoading: awaitsQuota, failureHelp: quotaFailure)
                        .help(quotaFailure ?? "7 天额度重置窗口内的账号口径费用，包含账号倍率，不是自然周。")
                    Divider().frame(height: 28)
                    usageMetric("周额度估算", snapshot.estimatedWeeklyCost, alignment: .leading,
                                isLoading: awaitsQuota && account.platform == "openai",
                                failureHelp: account.platform == "openai" ? quotaFailure : nil)
                }
            }.padding(.vertical, 4)

            if account.isAPIKeyAccount {
                HStack(spacing: 12) {
                    textMetric("今日 Token", compactTokenCount(todayStats?.tokens),
                               isLoading: todayStats == nil && todayUsageError == nil && isRefreshingTodayUsage,
                               failureHelp: dailyFailure(.tokens))
                        .help(dailyFailure(.tokens) ?? "\(todayStats?.tokens.map { $0.formatted() } ?? "—") Token · 服务端时区今日零点起，含输入、输出、缓存写入和缓存读取。")
                    // Match the first row's three equal columns without drawing
                    // separators or placeholder metrics for the two empty cells.
                    Divider().frame(height: 28).hidden()
                    Color.clear.frame(maxWidth: .infinity).frame(height: 28).accessibilityHidden(true)
                    Divider().frame(height: 28).hidden()
                    Color.clear.frame(maxWidth: .infinity).frame(height: 28).accessibilityHidden(true)
                }
            }

            if account.supportsSubscription {
                if subscription?.isComplete == true {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            textMetric("周期消费", subscriptionMoney(subscriptionSample?.actualCost, unit: actualCostCurrency),
                                       isSensitive: true, isLoading: showsSubscriptionLoading, failureHelp: subscriptionError)
                                .help(subscriptionError ?? "当前订阅周期实际扣费（含倍率）")
                            Divider().frame(height: 28)
                            textMetric("订阅成本", subscriptionMoney(subscription?.monthlyPrice, unit: subscriptionCostCurrency), isSensitive: true)
                            Divider().frame(height: 28)
                            textMetric("周期", subscriptionCycle?.shortLabel ?? "—")
                                .help(subscriptionCycle?.label ?? "周期不可用")
                        }
                    }
                } else {
                    Text("订阅未配置完整 · 不纳入消费与成本汇总")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            if !stale && snapshot.usageError == nil && snapshot.needsQuotaAttention(at: Date()) {
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

    private func usageMetric(_ title: String, _ value: Double?, alignment: HorizontalAlignment, isLoading: Bool = false,
                             failureHelp: String? = nil) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                FieldFailureIndicator(message: failureHelp, label: title)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Group {
                if isLoading { ProgressView().controlSize(.mini).accessibilityLabel("\(title)加载中") }
                else { SensitiveAmountText(value: money(value), label: title) }
            }.font(.system(size: 12, weight: .medium)).monospacedDigit()
                .opacity(failureHelp == nil ? 1 : 0.65)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(height: 16)
        }.frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    private func textMetric(_ title: String, _ value: String, isSensitive: Bool = false, isLoading: Bool = false,
                            failureHelp: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                FieldFailureIndicator(message: failureHelp, label: title)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Group {
                if isLoading { ProgressView().controlSize(.mini).accessibilityLabel("\(title)加载中") }
                else if isSensitive { SensitiveAmountText(value: value, label: title) }
                else { Text(value) }
            }.font(.system(size: 12, weight: .medium)).monospacedDigit()
                .opacity(failureHelp == nil ? 1 : 0.65)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(height: 16)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func quotaLines(at date: Date) -> some View {
        if account.isAPIKeyAccount {
            LocalQuotaSection(quotas: account.localQuotas, unavailable: stale || accountReadError != nil, date: date)
        }
        if account.supportsUsageQuery {
            upstreamQuotaLines(at: date)
                .opacity(quotaFailure == nil ? 1 : 0.65)
                .help(quotaFailure ?? "上游额度窗口")
        } else if !account.isAPIKeyAccount {
            Text("该账号暂无可用的额度数据").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: PanelSizing.emptyQuotaHeight, alignment: .leading)
        }
    }

    @ViewBuilder
    private func upstreamQuotaLines(at date: Date) -> some View {
        if account.platform == "gemini" {
            VStack(spacing: PanelSizing.quotaRowSpacing) {
                if let window = snapshot.usage?.geminiSharedDaily { usageLine(title: "日共享", percentage: window.percentage, resetCountdown: ResetCountdown.text(until: window.resetDate, at: date)) }
                if let window = snapshot.usage?.geminiProDaily { usageLine(title: "Pro 日", percentage: window.percentage, resetCountdown: ResetCountdown.text(until: window.resetDate, at: date)) }
                if let window = snapshot.usage?.geminiFlashDaily { usageLine(title: "Flash 日", percentage: window.percentage, resetCountdown: ResetCountdown.text(until: window.resetDate, at: date)) }
            }
        } else {
            VStack(spacing: PanelSizing.quotaRowSpacing) {
                usageLine(title: "5 小时", percentage: snapshot.usage?.fiveHour?.percentage,
                          resetCountdown: ResetCountdown.text(until: snapshot.usage?.fiveHour?.resetDate, at: date))
                usageLine(title: "7 天", percentage: snapshot.weeklyPercentage,
                          resetCountdown: ResetCountdown.text(until: snapshot.usage?.sevenDay?.resetDate, at: date))
            }
        }
    }

    private func usageLine(title: String, percentage: Double?, resetCountdown: String? = nil) -> some View {
        QuotaProgressLine(title: title, percentage: percentage, resetCountdown: resetCountdown, isLoading: awaitsQuota)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            detail("账号 ID", "#\(account.id)")
            detail("类型", account.typeLabel)
            if account.supportsUsageQuery && !account.isAPIKeyAccount {
                detail("5 小时重置", resetText(snapshot.usage?.fiveHour))
                detail("7 天重置", resetText(snapshot.usage?.sevenDay))
            }
            detail("今日用量（标准价）", money(todayCost), isSensitive: true)
            if account.isAPIKeyAccount {
                detail("今日账号费用", money(todayStats?.accountCost), isSensitive: true)
                detail("今日用户扣费", subscriptionMoney(todayStats?.userCost.map { Decimal($0) }, unit: actualCostCurrency), isSensitive: true)
                detail("今日请求", todayStats?.requests.map { $0.formatted() } ?? "—")
                detail("今日 Token", todayStats?.tokens.map { $0.formatted() } ?? "—")
                detail("限额来源", "sub2api 管理员配置 · 非上游余额")
                ForEach(account.localQuotas) { quota in
                    detail(quota.title + "（已用 / 上限）", "\(money(quota.used)) / \(money(quota.limit))", isSensitive: true)
                    if let date = quota.resetDate {
                        detail(quota.title + "重置", date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let accountUpdatedAt { detail("限额读取时间", accountUpdatedAt.formatted(date: .abbreviated, time: .standard)) }
            } else {
                detail("本周用量", money(snapshot.weeklyCost), isSensitive: true)
            }
            if account.supportsSubscription, let subscriptionCycle { detail("订阅周期（含首尾）", subscriptionCycle.label) }
            if account.supportsSubscription, let subscriptionSample {
                detail("本周期消费采样", subscriptionSample.sampledAt.formatted(date: .abbreviated, time: .shortened))
                detail("消费口径", subscriptionSample.includesAdmin ? "实际扣费 · 含 Admin" : "实际扣费 · 不含 Admin")
                detail("周期时区", subscriptionSample.cycle.timeZoneID)
            }
            if let updated = snapshot.statisticsUpdatedAt {
                detail("计费统计采样", updated.formatted(date: .omitted, time: .standard))
            }
            if let rpm = account.currentRpm { detail("RPM", String(rpm)) }
            if let sessions = account.activeSessions { detail("活跃会话", String(sessions)) }
            if account.supportsUsageQuery, let usage = snapshot.usage {
                if let value = usage.sevenDaySonnet?.percentage { usageLine(title: "Sonnet", percentage: value) }
                if let value = usage.geminiSharedDaily?.percentage { usageLine(title: "日共享", percentage: value) }
                if let value = usage.geminiProDaily?.percentage { usageLine(title: "Pro 日", percentage: value) }
                if let value = usage.geminiFlashDaily?.percentage { usageLine(title: "Flash 日", percentage: value) }
                detail("额度采样", usage.updatedAt.flatMap(parseAPIDate).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "上游未提供时间")
            }
            if let error = accountReadError { Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let error = todayUsageError { Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let error = subscriptionError { Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if account.supportsUsageQuery, let error = snapshot.usageError {
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
