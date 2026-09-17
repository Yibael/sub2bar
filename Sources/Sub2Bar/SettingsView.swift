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
                                Text("更改尚未保存，当前显示已保存服务器的账号。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            PinnedAccountsView(store: store, configure: { page = .connection })
                        }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 12) {
                    if store.isSaving { ProgressView().controlSize(.small) }
                    Text(message ?? (changed ? "有未保存的更改" : (page == .accounts ? "账号与订阅设置自动保存" : "")))
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
                TextField("服务器地址", text: $draft.serverURL, prompt: Text("https://sub2api.example.com"))
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

            Section {
                Toggle("允许 HTTP 连接", isOn: $draft.allowHTTP).toggleStyle(.switch)
            } footer: {
                if draft.allowHTTP {
                    Text("HTTP 会明文传输 Admin Key，仅用于可信网络。")
                }
            }

            Section {
                LabeledContent("密钥存储", value: "本机文件")
            } footer: {
                Text("密钥以明文保存在本机，同一用户下的其他程序可能读取。")
            }
        }.formStyle(.grouped).disabled(store.isSaving || store.isLoadingCredential || testing)
    }

    private var refreshForm: some View {
        Form {
            Section {
                Picker("刷新间隔", selection: $draft.accountRefreshInterval) {
                    ForEach(Configuration.accountIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) 秒").tag(interval)
                    }
                }.accessibilityLabel("账号状态刷新间隔")
            } header: { Text("账号状态") }
            footer: { Text("更新并发、账号状态及今日用量（标准价）。") }

            Section {
                Picker("刷新间隔", selection: $draft.refreshInterval) {
                    ForEach(Configuration.quotaIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) 秒").tag(interval)
                    }
                }.accessibilityLabel("额度与费用刷新间隔")
            } header: { Text("额度与费用") }
            footer: { Text("更新额度使用率、重置时间、用量费用及周额度估算。") }

            Section {
                Picker("刷新间隔", selection: $draft.statisticsRefreshInterval) {
                    ForEach(Configuration.statisticsIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) 秒").tag(interval)
                    }
                }.accessibilityLabel("实际消费刷新间隔")
            } header: { Text("实际消费") }
            footer: {
                Text("更新今日及当前订阅周期的实际消费。")
            }
        }.formStyle(.grouped).disabled(busy)
    }

    private var statisticsForm: some View {
        Form {
            Section {
                TextField("实际消费", text: $draft.actualCostCurrency, prompt: Text("例如 ¥、$、€"))
                    .textFieldStyle(.roundedBorder)
                TextField("订阅成本", text: $draft.subscriptionCostCurrency, prompt: Text("例如 ¥、$、€"))
                    .textFieldStyle(.roundedBorder)
            } header: { Text("货币符号") }
            footer: {
                Text("仅更改显示符号，不换算金额。")
            }
            Section {
                Toggle("包含 Admin 消费", isOn: $draft.includeAdminUsage).toggleStyle(.switch)
                    .help("影响今日与周期实际消费，不影响标准价用量、额度或订阅成本。")
            } header: { Text("统计范围") }
            footer: {
                Text("按实际扣费金额统计（含倍率），仅汇总已 Pin 且订阅配置完整的 OAuth 账号。")
            }
            Section {
                Picker("时区", selection: $draft.subscriptionTimeZoneID) {
                    ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + [draft.subscriptionTimeZoneID])).sorted(), id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
            } header: { Text("统计时区") }
            footer: {
                Text("每日及订阅周期均以所选时区的 00:00 为界。续费日超出当月天数时，按月末计算。")
            }
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
