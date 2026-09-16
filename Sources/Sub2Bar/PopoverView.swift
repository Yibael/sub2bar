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

    init(store: AppStore, openSettings: @escaping () -> Void,
         version: String = AppVersion.display(in: Bundle.main.infoDictionary)) {
        self.store = store
        self.openSettings = openSettings
        self.version = version
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.isConfigured { welcome }
            else if store.needsCredentialAccess { credentialRequired }
            else if store.pinCount == 0 { noPins }
            else { dashboard }
            footer
        }
        .frame(width: 432, height: 660)
        .background(NeutralPanelBackground())
        .tint(Theme.accent)
        .environment(\.isMenuPanelSurface, true)
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
            QuotaRefreshButton(isLoading: store.showsQuotaLoading,
                               isEnabled: !store.needsCredentialAccess && store.isPanelVisible && store.isConfigured && store.pinCount > 0,
                               action: store.refresh)
        }
        .padding(.horizontal, 20).padding(.vertical, 17)
    }

    private var refreshStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            QuotaRefreshStatus(text: refreshLabel(at: context.date))
        }
    }

    private func refreshLabel(at date: Date) -> String {
        if store.needsCredentialAccess { return store.isLoadingCredential ? "载入中" : "待配置" }
        if store.showsQuotaLoading { return "额度刷新 00:00" }
        if let seconds = store.secondsUntilRefresh(at: date) {
            return String(format: "额度刷新 %02d:%02d", seconds / 60, seconds % 60)
        }
        return store.pinCount == 0 ? "" : "已暂停"
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
            HStack(spacing: 10) {
                summaryCard("总并发", value: store.concurrency.map(String.init) ?? "—",
                            suffix: store.concurrencyLimit.map { "/ \($0)" } ?? "",
                            note: store.snapshots.count == store.pinCount ? "当前 / 上限" : "已读取 \(store.snapshots.count)/\(store.pinCount) 个账号")
                summaryCard("周额度估算", value: money(store.estimatedTotal),
                            suffix: "", note: "覆盖 \(store.estimatedAccounts.count)/\(store.pinCount) 个账号")
                    .help("仅汇总已 Pin 的 OpenAI 账号。本周计费 ÷ 周已用比例，不是余额。")
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
            AccountListSummary(overview: store.accountOverview)
            if store.showsAccountFilters {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索已 Pin 账号", text: $store.search).textFieldStyle(.plain)
                    if !store.search.isEmpty {
                        Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).accessibilityLabel("清空搜索")
                    }
                    Picker("平台", selection: $store.platform) {
                        ForEach(store.platforms, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 100).controlSize(.small)
                }
                .font(.system(size: 12)).padding(9)
                .insetSurface(cornerRadius: 7)
            }

            if store.snapshots.isEmpty && store.pinnedAccountErrors.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "tray")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(store.isRefreshing ? "加载中…" : (store.errorMessage == nil ? "暂无数据" : "加载失败"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.pinnedIDs.filter { store.pinnedAccountErrors[$0] != nil }, id: \.self) { id in
                            VStack(alignment: .leading, spacing: 8) {
                                Label("账号 #\(id) 加载失败", systemImage: "exclamationmark.circle")
                                    .font(.system(size: 12, weight: .medium))
                                Text(store.pinnedAccountErrors[id] ?? "")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(13).insetSurface(cornerRadius: 9)
                        }
                        ForEach(store.filtered.filter { store.pinnedAccountErrors[$0.id] == nil }) { snapshot in
                            AccountCard(snapshot: snapshot, stale: store.errorMessage != nil,
                                        isPanelVisible: store.isPanelVisible)
                        }
                        if store.filtered.isEmpty && store.pinnedAccountErrors.isEmpty {
                            Text("没有匹配的账号").foregroundStyle(.secondary).padding(30)
                        }
                    }.padding(.bottom, 3)
                }.scrollIndicators(.hidden)
            }
        }.padding(.horizontal, 18).padding(.bottom, 12).frame(maxHeight: .infinity)
    }

    private func summaryCard(_ title: String, value: String, suffix: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 25, weight: .semibold)).minimumScaleFactor(0.7)
                Text(suffix).font(.system(size: 14, weight: .medium)).foregroundStyle(.tertiary)
            }.lineLimit(1).monospacedDigit()
            Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
        .insetSurface(cornerRadius: 9)
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

struct AccountCard: View {
    let snapshot: AccountSnapshot
    let stale: Bool
    let isPanelVisible: Bool
    @State private var expanded = false
    private var account: Account { snapshot.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
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
            }.buttonStyle(.plain).help("展开账号详情")

            if isPanelVisible {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    quotaLines(at: context.date)
                }
            } else {
                quotaLines(at: .now)
            }
            HStack(spacing: 4) {
                Text("周额度估算")
                Text(money(snapshot.estimatedWeeklyCost)).foregroundStyle(.primary).monospacedDigit()
                Spacer()
                Text("本周计费")
                Text(money(snapshot.weeklyCost)).monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.secondary)

            if snapshot.usageError != nil {
                Label("额度读取失败", systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.primary)
            } else if (snapshot.weeklyPercentage ?? 0) >= 90 || (snapshot.usage?.fiveHour?.percentage ?? 0) >= 90 {
                Label("额度接近上限", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.primary)
            }
            if expanded { details }
        }
        .padding(13).insetSurface(cornerRadius: 9)
        .opacity(stale ? 0.65 : 1)
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
            Text(percentage.map { String(format: "%.1f%%", $0) } ?? "—")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.usageColor(percentage)).frame(width: 47, alignment: .trailing)
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
            detail("本周计费", money(snapshot.weeklyCost))
            if let updated = snapshot.statisticsUpdatedAt {
                detail("计费统计采样", updated.formatted(date: .omitted, time: .standard))
            }
            detail("RPM / 活跃会话", "\(account.currentRpm.map(String.init) ?? "—") / \(account.activeSessions.map(String.init) ?? "—")")
            if let limit = account.quotaWeeklyLimit, limit > 0 { detail("配置的周限额", money(limit)) }
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
    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).textSelection(.enabled) }
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
