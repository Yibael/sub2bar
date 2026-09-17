import SwiftUI
import Sub2BarCore

struct PinnedAccountsView: View {
    @ObservedObject var store: AppStore
    let configure: () -> Void
    @State private var search = ""
    @State private var onlyPinned = false
    @State private var onlyOAuth = false
    @State private var editingAccount: Account?

    private var directory: AccountDirectoryPresentation {
        AccountDirectoryPresentation(accounts: store.availableAccounts, pinnedIDs: store.pinnedIDs,
            hasLoaded: store.hasLoadedAccounts, search: search, onlyPinned: onlyPinned, onlyOAuth: onlyOAuth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if !store.isConfigured {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("未配置服务器").font(.system(size: 13))
                    Button("配置连接", action: configure).buttonStyle(NeutralButtonStyle(.primary))
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                toolbar
                if let error = store.accountsError {
                    Label(error + (store.hasLoadedAccounts ? " 显示上次列表。" : ""), systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).insetSurface(cornerRadius: 8)
                }
                accountList
                footer
            }
        }
        .sheet(item: $editingAccount) { account in
            SubscriptionEditor(store: store, account: account)
        }
        .onChange(of: store.configuration.serverURL) { _, _ in editingAccount = nil }
        .task(id: store.accountDirectoryIdentity) { store.loadAvailableAccountsIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("账号管理").font(.system(size: 22, weight: .bold))
                Text("管理切换顺序与账号订阅")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { store.loadAvailableAccounts() } label: {
                HStack(spacing: 6) {
                    ZStack {
                        if store.isLoadingAccounts { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: 12, height: 12)
                    Text(store.isLoadingAccounts ? "刷新中" : "刷新账号")
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(store.isLoadingAccounts || !store.isConfigured || store.isSaving)
            .help("立即刷新完整账号列表")
        }
    }

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称、平台或 ID", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("搜索账号")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("清除搜索").accessibilityLabel("清除账号搜索")
                }
            }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 34).insetSurface(cornerRadius: 8)
            HStack(spacing: 10) {
                Picker("账号范围", selection: $onlyPinned) {
                    Text(store.hasLoadedAccounts ? "全部 \(store.availableAccounts.count)" : "全部").tag(false)
                    Text("已 Pin \(store.pinCount)").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 176)
                Toggle("仅 OAuth", isOn: $onlyOAuth)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Spacer(minLength: 0)
                Text(store.hostLabel).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).help(store.hostLabel)
            }
        }
    }

    private var accountList: some View {
        let content = directory
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !content.pinned.isEmpty {
                    accountSection("面板切换", accounts: content.pinned, pinned: true)
                }
                if !content.others.isEmpty {
                    accountSection("其他账号", accounts: content.others, pinned: false)
                }
                if !content.missingPinnedIDs.isEmpty {
                    missingSection(content.missingPinnedIDs)
                }
                if content.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.rectangle.stack").font(.system(size: 24))
                        Text(emptyLabel).font(.system(size: 12))
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 52)
                }
            }.padding(1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accountSection(_ title: String, accounts: [Account], pinned: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.medium)
                Text("\(accounts.count)").monospacedDigit().foregroundStyle(.tertiary)
                if pinned {
                    Image(systemName: "info.circle").foregroundStyle(.tertiary)
                        .help("已 Pin 账号按顺序在面板中切换。使用上下箭头调整顺序；订阅价格与续费日完整时纳入统计。")
                        .accessibilityLabel("已 Pin 账号按顺序切换，使用上下箭头调整")
                }
                Spacer()
                Text("月订阅").foregroundStyle(.tertiary)
                    .frame(width: 126, alignment: .leading)
                Image(systemName: "pin").foregroundStyle(.tertiary).frame(width: 28)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12)
            LazyVStack(spacing: 0) {
                ForEach(accounts) { account in
                    accountRow(account)
                    if account.id != accounts.last?.id {
                        Divider().padding(.leading, 12).padding(.trailing, 12)
                    }
                }
            }
            .background(pinned ? Color.accentColor.opacity(0.025) : .clear)
            .insetSurface(cornerRadius: 10)
        }
    }

    private func missingSection(_ ids: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("列表中缺失的 Pin", systemImage: "exclamationmark.circle")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 10) {
                    pinOrderControls(id)
                    Text("账号 #\(id)").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("取消 Pin") { store.setPinned(false, id: id) }
                        .buttonStyle(.bordered).controlSize(.small)
                }.padding(10).insetSurface(cornerRadius: 8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let date = store.accountsUpdatedAt {
                Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
                    .help("列表更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
            } else { Text("账号列表尚未加载") }
            Spacer()
            Label("配置仅保存在本地", systemImage: "internaldrive")
        }.font(.system(size: 10)).foregroundStyle(.tertiary)
    }

    private var emptyLabel: String {
        if store.isLoadingAccounts { return "正在获取全部账号…" }
        if store.needsCredentialAccess { return "请先在连接设置中配置有效密钥" }
        if !store.hasLoadedAccounts { return "点击“刷新账号”重试" }
        return store.availableAccounts.isEmpty ? "服务器中暂无账号" : "没有匹配的账号"
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 10) {
            if store.isPinned(account.id) {
                pinOrderControls(account.id)
            }
            AccountDirectoryIdentity(account: account)
                .frame(maxWidth: .infinity, alignment: .leading)
            subscriptionCell(account).frame(width: 126, alignment: .leading)
            Button { store.setPinned(!store.isPinned(account.id), id: account.id) } label: {
                Image(systemName: store.isPinned(account.id) ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
            }.buttonStyle(AccountDirectoryActionStyle(selected: store.isPinned(account.id)))
                .help(store.isPinned(account.id) ? "移出切换列表（取消 Pin）" : "加入面板切换（Pin）")
                .accessibilityLabel(store.isPinned(account.id) ? "取消 Pin \(account.name)" : "Pin \(account.name)，加入切换列表")
        }.padding(.horizontal, 12).padding(.vertical, 12)
            .accessibilityElement(children: .contain)
    }

    private func pinOrderControls(_ id: Int) -> some View {
        let index = store.pinnedIDs.firstIndex(of: id) ?? 0
        return HStack(spacing: 1) {
            Text("\(index + 1)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary).frame(minWidth: 12).help("切换顺序 \(index + 1)")
            VStack(spacing: 0) {
                Button { store.movePinned(id, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 18, height: 18) }
                    .disabled(index == 0).accessibilityLabel("账号 #\(id) 切换顺序上移")
                    .help("切换顺序上移")
                Button { store.movePinned(id, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 18, height: 18) }
                    .disabled(index == store.pinCount - 1).accessibilityLabel("账号 #\(id) 切换顺序下移")
                    .help("切换顺序下移")
            }.buttonStyle(.borderless).font(.system(size: 8, weight: .semibold))
        }.fixedSize()
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func subscriptionCell(_ account: Account) -> some View {
        if account.supportsSubscription {
            let value = store.subscriptions[account.id]
            Button { editingAccount = account } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let value, value.isComplete, let day = value.renewalDay {
                            Text(subscriptionMoney(value.monthlyPrice, unit: store.configuration.subscriptionCostCurrency) + " / 月")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                            Text("每月 \(day) 日续费").font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Text(value == nil ? "设置订阅" : "补全订阅")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 5).frame(height: 42)
            }.buttonStyle(AccountDirectoryActionStyle())
                .help(subscriptionHelp(account.id))
                .accessibilityLabel("配置 \(account.name) 的订阅：\(subscriptionHelp(account.id))")
        } else {
            Text("—").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 5)
                .help("仅 OAuth 账号支持订阅配置")
        }
    }

    private func subscriptionHelp(_ id: Int) -> String {
        guard let value = store.subscriptions[id], value.isComplete, let day = value.renewalDay else {
            return "设置月订阅价格与续费日；配置完整的 Pin 账号才纳入统计"
        }
        return "\(subscriptionMoney(value.monthlyPrice, unit: store.configuration.subscriptionCostCurrency)) / 月，每月 \(day) 日续费；点击编辑"
    }
}

private struct AccountDirectoryIdentity: View {
    let account: Account

    private var typeLabel: String {
        switch account.type {
        case "oauth": return "OAuth"
        case "apikey", "api_key", "api-key": return "API Key"
        case "setup-token": return "Setup Token"
        default: return account.type ?? "类型未知"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(platform: account.platform).frame(width: 28, height: 28)
                .padding(3).insetSurface(cornerRadius: 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(account.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle).help(account.name)
                Text("\(account.platformLabel) · \(typeLabel) · #\(account.id)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(account.isAvailable ? Color.green : Color.secondary).frame(width: 4, height: 4)
                    Text(account.stateLabel(at: Date()))
                }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct AccountDirectoryActionStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        AccountDirectoryActionSurface(selected: selected, pressed: configuration.isPressed, content: configuration.label)
    }
}

private struct AccountDirectoryActionSurface<Content: View>: View {
    let selected: Bool
    let pressed: Bool
    let content: Content
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        content
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(selected ? Color.accentColor.opacity(pressed ? 0.2 : 0.09) : Color.primary.opacity(pressed ? 0.09 : (hovered ? 0.045 : 0)),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 }
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
