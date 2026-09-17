import SwiftUI
import Sub2BarCore

struct PinnedAccountsView: View {
    @ObservedObject var store: AppStore
    let configure: () -> Void
    @State private var search = ""
    @State private var onlyPinned = false
    @State private var onlyOAuth = false
    @State private var editingAccount: Account?

    private var filtered: [Account] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.orderedAvailableAccounts.filter {
            (!onlyPinned || store.isPinned($0.id)) && (!onlyOAuth || $0.supportsSubscription) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
            $0.platformLabel.localizedCaseInsensitiveContains(query) || String($0.id).contains(query))
        }
    }
    private var missingPins: [Int] {
        guard store.hasLoadedAccounts else { return [] }
        let known = Set(store.availableAccounts.map(\.id))
        return store.pinnedIDs.filter { !known.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("账号").font(.system(size: 14, weight: .semibold))
                    Text("\(store.hostLabel) · \(store.pinCount) 个已 Pin")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if store.isLoadingAccounts { ProgressView().controlSize(.small) }
                Button(store.hasLoadedAccounts ? "刷新全部账号" : "获取全部账号") { store.loadAvailableAccounts() }
                    .buttonStyle(.bordered)
                    .disabled(store.isLoadingAccounts || !store.isConfigured || store.isSaving)
            }
            Text("已 Pin 账号按切换顺序排列，可用上下箭头调整。只有 Pin 的账号参与面板切换；订阅统计仍要求价格与续费日完整。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !store.isConfigured {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("未配置服务器").font(.system(size: 13))
                    Button("配置连接", action: configure).buttonStyle(NeutralButtonStyle(.primary))
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索账号名称、平台或 ID", text: $search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(10).insetSurface(cornerRadius: 7)
                HStack(spacing: 18) {
                    Toggle("仅已 Pin", isOn: $onlyPinned)
                    Toggle("仅 OAuth", isOn: $onlyOAuth)
                }.toggleStyle(.checkbox).font(.system(size: 11))

                if let error = store.accountsError {
                    Label(error + (store.hasLoadedAccounts ? " 显示上次列表。" : ""), systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { account in
                            accountRow(account)
                            Divider()
                        }
                        if !missingPins.isEmpty {
                            Text("列表中缺失的 Pin")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13)
                            ForEach(missingPins, id: \.self) { id in
                                HStack {
                                    Label("账号 #\(id)", systemImage: "exclamationmark.circle")
                                    Spacer()
                                    pinOrderControls(id)
                                    Button("取消 Pin") { store.setPinned(false, id: id) }
                                        .buttonStyle(NeutralButtonStyle(.outline))
                                }.font(.system(size: 12)).padding(.vertical, 6)
                            }
                        }
                        if filtered.isEmpty && missingPins.isEmpty {
                            Text(emptyLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 48)
                        }
                    }
                }.frame(maxHeight: .infinity)

                HStack {
                    Text(store.hasLoadedAccounts ? "共 \(store.availableAccounts.count) 个账号 · \(store.pinCount) 个已 Pin" : "账号列表尚未加载")
                    Spacer()
                    Text("顺序与配置保存本地")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if let date = store.accountsUpdatedAt {
                    Text("列表更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
        .sheet(item: $editingAccount) { account in
            SubscriptionEditor(store: store, account: account)
        }
        .onChange(of: store.configuration.serverURL) { _, _ in editingAccount = nil }
        .task(id: store.accountDirectoryIdentity) { store.loadAvailableAccountsIfNeeded() }
    }

    private var emptyLabel: String {
        if store.isLoadingAccounts { return "正在获取全部账号…" }
        if store.needsCredentialAccess { return "请先在连接设置中配置有效密钥" }
        if !store.hasLoadedAccounts { return "点击“获取全部账号”重试" }
        return store.availableAccounts.isEmpty ? "服务器中暂无账号" : "没有匹配的账号"
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 12) {
            ProviderIcon(platform: account.platform)
                .frame(width: 30, height: 30).insetSurface(cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(account.platformLabel) · #\(account.id) · \(account.stateLabel(at: Date()))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if account.supportsSubscription {
                    Text(subscriptionLabel(account.id)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if account.supportsSubscription {
                Button { editingAccount = account } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(NeutralButtonStyle(.ghost, compact: true))
                    .help("设置月订阅价格与续费日")
                    .accessibilityLabel("配置 \(account.name) 的订阅")
            }
            if store.isPinned(account.id) {
                pinOrderControls(account.id)
                Button { store.setPinned(false, id: account.id) } label: { Image(systemName: "pin.slash") }
                    .buttonStyle(NeutralButtonStyle(.ghost, compact: true))
                    .help("移出切换列表（取消 Pin）")
                    .accessibilityLabel("取消 Pin \(account.name)")
            } else {
                Button { store.setPinned(true, id: account.id) } label: {
                    Label("加入切换", systemImage: "pin")
                }.buttonStyle(NeutralButtonStyle(.outline))
                    .accessibilityLabel("Pin \(account.name)，加入切换列表")
            }
        }.padding(.vertical, 12)
    }

    private func pinOrderControls(_ id: Int) -> some View {
        let index = store.pinnedIDs.firstIndex(of: id) ?? 0
        return HStack(spacing: 5) {
            Text("\(index + 1)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(minWidth: 18).help("切换顺序 \(index + 1)")
            VStack(spacing: 2) {
                Button { store.movePinned(id, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 18, height: 14) }
                    .disabled(index == 0).accessibilityLabel("账号 #\(id) 切换顺序上移")
                Button { store.movePinned(id, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 18, height: 14) }
                    .disabled(index == store.pinCount - 1).accessibilityLabel("账号 #\(id) 切换顺序下移")
            }.buttonStyle(.plain).font(.system(size: 9, weight: .semibold))
        }.padding(.horizontal, 6).padding(.vertical, 4).insetSurface(cornerRadius: 5)
            .accessibilityElement(children: .contain)
    }

    private func subscriptionLabel(_ id: Int) -> String {
        guard let value = store.subscriptions[id] else { return "订阅未配置 · 不参与统计" }
        guard value.isComplete, let day = value.renewalDay else { return "订阅配置未完整 · 不参与统计" }
        return "\(subscriptionMoney(value.monthlyPrice, unit: store.configuration.subscriptionCostCurrency))/月 · 每月 \(day) 日续费"
    }
}

struct SubscriptionEditor: View {
    @ObservedObject var store: AppStore
    let account: Account
    private let serverIdentity: String
    @Environment(\.dismiss) private var dismiss
    @State private var price: String
    @State private var day: Int
    @State private var error: String?

    init(store: AppStore, account: Account) {
        self.store = store; self.account = account; serverIdentity = store.configuration.serverURL
        let value = store.subscriptions[account.id]
        _price = State(initialValue: value?.monthlyPrice.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _day = State(initialValue: value?.renewalDay ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("订阅设置").font(.title2.bold())
            Text("\(account.name) · #\(account.id)").foregroundStyle(.secondary).lineLimit(1)
            Form {
                TextField("月订阅价格（\(store.configuration.subscriptionCostCurrency)）", text: $price, prompt: Text("例如 200.00"))
                    .textFieldStyle(.roundedBorder)
                Picker("每月续费日", selection: $day) {
                    Text("未设置").tag(0)
                    ForEach(1...31, id: \.self) { Text("每月 \($0) 日").tag($0) }
                }
            }
            Text("仅保存本地。价格可填 0，最多两位小数；缺少价格或续费日不纳入统计。短月取月末，长月恢复原续费日。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("统计时区：\(store.configuration.subscriptionTimeZoneID)（可在“消费统计”修改）")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("清除配置") { save(clear: true) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(clear: false) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 430)
    }

    private func save(clear: Bool) {
        do {
            guard serverIdentity == store.configuration.serverURL else { throw SubscriptionError.invalidConfiguration }
            let amount = clear ? nil : try AccountSubscription.parseMonthlyPrice(price)
            let value = clear || (amount == nil && day == 0) ? nil : AccountSubscription(monthlyPrice: amount, renewalDay: day == 0 ? nil : day)
            try store.saveSubscription(value, for: account)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
