import SwiftUI
import Sub2BarCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case connection = "连接", refresh = "刷新", accounts = "账号管理", statistics = "消费统计"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .connection: return "network"
        case .refresh: return "arrow.clockwise"
        case .accounts: return "person.2"
        case .statistics: return "chart.bar"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var draft: Configuration
    @State private var key = ""
    @State private var loadedIdentity: String?
    @State private var page: SettingsPage = .connection
    @State private var message: String?
    @State private var connectionMessage: String?
    @State private var testSucceeded = false
    @State private var testing = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?

    init(store: AppStore, page: SettingsPage = .connection) {
        self.store = store
        _page = State(initialValue: page)
        var initial = store.configuration
        initial.refreshInterval = initial.effectiveRefreshInterval
        initial.accountRefreshInterval = initial.effectiveAccountRefreshInterval
        initial.statisticsRefreshInterval = initial.effectiveStatisticsRefreshInterval
        _draft = State(initialValue: initial)
    }

    private var busy: Bool { testing || store.isSaving || store.isLoadingCredential }
    private var changed: Bool { draft != store.configuration || key != (store.cachedKey(for: draft) ?? "") }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Label("Sub2Bar", systemImage: "server.rack")
                    .font(.system(size: 15, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 24)
                List(SettingsPage.allCases, selection: $page) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                        .padding(.vertical, 3)
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                Text("版本 \(AppVersion.display(in: Bundle.main.infoDictionary))")
                    .font(.caption).foregroundStyle(.tertiary).padding(18)
            }.frame(width: 172).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if page != .accounts {
                    Text(page.rawValue).font(.system(size: 22, weight: .bold))
                        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 8)
                }
                Group {
                    switch page {
                    case .connection: connectionForm
                    case .refresh: refreshForm
                    case .statistics: statisticsForm
                    case .accounts:
                        VStack(spacing: 10) {
                            if draft != store.configuration {
                                Text("设置尚未保存，账号列表使用已保存的服务器。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            PinnedAccountsView(store: store, configure: { page = .connection })
                        }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 12) {
                    if store.isSaving { ProgressView().controlSize(.small) }
                    Text(message ?? (changed ? "有未保存的更改" : (page == .accounts ? "Pin 与订阅更改自动保存" : "")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("保存设置", action: save)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(busy || !changed || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.horizontal, 28).padding(.vertical, 17)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 760, height: 620)
        .task {
            await store.prepareCredentials()
            guard key.isEmpty else { return }
            key = store.cachedKey(for: draft) ?? ""
            loadedIdentity = try? draft.baseURL().absoluteString
        }
        .onDisappear { connectionTask?.cancel() }
        .onChange(of: draft.serverURL) { _, _ in
            message = nil; connectionMessage = nil
            if let loadedIdentity, loadedIdentity != (try? draft.baseURL().absoluteString) {
                key = ""; self.loadedIdentity = nil
            }
        }
        .onChange(of: key) { _, value in
            message = nil
            connectionMessage = nil
            if !value.isEmpty { loadedIdentity = try? draft.baseURL().absoluteString }
        }
        .onChange(of: draft.refreshInterval) { _, _ in message = nil }
        .onChange(of: draft.accountRefreshInterval) { _, _ in message = nil }
        .onChange(of: draft.statisticsRefreshInterval) { _, _ in message = nil }
        .onChange(of: draft.includeAdminUsage) { _, _ in message = nil }
        .onChange(of: draft.subscriptionTimeZoneID) { _, _ in message = nil }
        .onChange(of: draft.actualCostCurrency) { _, _ in message = nil }
        .onChange(of: draft.subscriptionCostCurrency) { _, _ in message = nil }
        .onChange(of: draft.allowHTTP) { _, _ in message = nil; connectionMessage = nil }
    }

    private var connectionForm: some View {
        Form {
            Section {
                TextField("服务器 URL", text: $draft.serverURL, prompt: Text("https://sub2api.example.com"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Admin Key", text: $key, prompt: Text("输入管理员密钥"))
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    if let connectionMessage {
                        Label(connectionMessage, systemImage: testSucceeded ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("测试连接", action: testConnection).disabled(busy || key.isEmpty)
                }
            } header: { Text("服务器") }
            footer: { Text("支持反向代理子路径。打开菜单栏面板时，自动使用已保存的设置连接。") }

            Section {
                Toggle("允许 HTTP 连接", isOn: $draft.allowHTTP).toggleStyle(.switch)
            } footer: {
                Text(draft.allowHTTP ? "HTTP 会明文传输管理员密钥，仅用于可信的本机或内网。" : "默认使用 HTTPS 验证服务器证书。")
            }

            Section {
                LabeledContent("密钥存储", value: "当前 Mac · 本地文件")
            } footer: {
                Text("密钥未加密，文件仅允许当前用户读写。同一用户运行的其他程序仍可能读取。旧版钥匙串条目不会自动导入或删除。")
            }
        }.formStyle(.grouped).disabled(store.isSaving || store.isLoadingCredential || testing)
    }

    private var refreshForm: some View {
        Form {
            Section {
                Picker("账号状态刷新间隔", selection: $draft.accountRefreshInterval) {
                    ForEach(Configuration.accountIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) 秒").tag(interval)
                    }
                }
            } header: { Text("账号状态") }
            footer: { Text("更新并发、并发上限、调度及异常状态，并批量查询今日用量（标准价）。今日用量只读取 sub2api 本地统计，不查询上游。") }

            Section {
                Picker("额度与费用刷新间隔", selection: $draft.refreshInterval) {
                    ForEach(Configuration.quotaIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) 秒").tag(interval)
                    }
                }
            } header: { Text("额度与费用") }
            footer: { Text("一起更新使用比例、重置时间、窗口费用和周额度估算。使用普通查询，不强制刷新上游；sub2api 仍可能按需查询上游。") }

            Section {
                Picker("实际消费刷新间隔", selection: $draft.statisticsRefreshInterval) {
                    ForEach(Configuration.statisticsIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) 秒").tag(interval)
                    }
                }
            } header: { Text("实际消费 · 仅本地数据库") }
            footer: {
                Text("更新今日与周期实际消费，仅查询 sub2api 使用日志统计，不访问 OpenAI 等上游。独立于账号状态及额度刷新；账号较多或排除 Admin 时查询次数较多，可适当增大间隔。")
            }

            Section {
                Text("仅面板打开时自动刷新。请求完成后重新计时，失败时延后重试。点击刷新按钮可立即查询一次额度，但不强制刷新上游缓存。保存刷新间隔会保留已有数据。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(busy)
    }

    private var statisticsForm: some View {
        Form {
            Section {
                TextField("实际消费货币符号", text: $draft.actualCostCurrency, prompt: Text("例如 ¥、$、€"))
                    .textFieldStyle(.roundedBorder)
                TextField("订阅成本货币符号", text: $draft.subscriptionCostCurrency, prompt: Text("例如 ¥、$、€"))
                    .textFieldStyle(.roundedBorder)
            } header: { Text("货币符号") }
            footer: {
                Text("直接在金额前显示你填写的符号，例如 ¥230.87。两项可独立设置，不识别货币代码、不换算金额。订阅成本符号同步用于月价和账号列表；其他用量显示保持不变。")
            }
            Section {
                Toggle("将 Admin 消费纳入统计", isOn: $draft.includeAdminUsage).toggleStyle(.switch)
            } header: { Text("今日与周期实际消费") }
            footer: {
                Text("今日与周期实际消费均使用用户扣费金额 actual_cost（含倍率）。关闭后排除当前角色为 Admin 的用户消费；不影响账号卡片的今日标准价用量、周额度统计或订阅成本。")
            }
            Section {
                Picker("统计时区", selection: $draft.subscriptionTimeZoneID) {
                    ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + [draft.subscriptionTimeZoneID])).sorted(), id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
            } header: { Text("日期与周期边界") }
            footer: {
                Text("今日实际消费从此时区今日 00:00 起统计。每月续费日 00:00 划分周期，包含续费日至下月续费日前一天，例如 9 月 15 日至 10 月 14 日。短月取月末，之后恢复原续费日。按日统计，不代表精确扣款时刻。")
            }
            Section {
                Text("在“账号管理”中为 OAuth 账号填写月订阅价格和每月续费日。只有已 Pin 且配置完整的账号参与消费与成本汇总。")
                Text("价格、续费日和统计设置仅保存在当前 Mac，不写入 sub2api。实际消费刷新间隔在“刷新”中独立配置，默认 2 秒；失败退避，关闭面板停止请求。")
            }.font(.callout).foregroundStyle(.secondary)
        }.formStyle(.grouped).disabled(busy)
    }

    private func testConnection() {
        testing = true; connectionMessage = nil
        let config = draft; let candidate = key
        connectionTask = Task { @MainActor in
            defer { testing = false }
            do {
                let count = try await APIClient(configuration: config, key: candidate).testConnection()
                guard !Task.isCancelled else { return }
                testSucceeded = true; connectionMessage = "连接成功 · \(count) 个账号"
            } catch {
                guard !Task.isCancelled else { return }
                testSucceeded = false; connectionMessage = error.localizedDescription
            }
        }
    }
    private func save() {
        let candidate = draft; let candidateKey = key
        saveTask = Task { @MainActor in
            do {
                try await store.save(candidate, key: candidateKey)
                draft = store.configuration; key = store.cachedKey() ?? ""
                loadedIdentity = try? draft.baseURL().absoluteString
                message = "设置已保存"
            } catch { message = error.localizedDescription }
        }
    }
}
