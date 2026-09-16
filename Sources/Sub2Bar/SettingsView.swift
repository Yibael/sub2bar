import SwiftUI
import Sub2BarCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case connection = "连接", refresh = "刷新", accounts = "菜单栏账号"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .connection: return "network"
        case .refresh: return "arrow.clockwise"
        case .accounts: return "pin"
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

    init(store: AppStore) {
        self.store = store
        var initial = store.configuration
        initial.refreshInterval = initial.effectiveRefreshInterval
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
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                    .font(.caption).foregroundStyle(.tertiary).padding(18)
            }.frame(width: 172).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(page.rawValue).font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 8)
                Group {
                    switch page {
                    case .connection: connectionForm
                    case .refresh: refreshForm
                    case .accounts:
                        VStack(spacing: 10) {
                            if draft != store.configuration {
                                Text("连接设置尚未保存，账号列表使用已保存的服务器。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            PinnedAccountsView(store: store, configure: { page = .connection })
                        }.padding(.horizontal, 28).padding(.vertical, 16)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 12) {
                    if store.isSaving { ProgressView().controlSize(.small) }
                    Text(message ?? (changed ? "有未保存的更改" : ""))
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
                LabeledContent("当前并发与上限", value: "2 秒")
                LabeledContent("调度、停用、错误与限流状态", value: "5 秒")
                Picker("额度快照刷新", selection: $draft.refreshInterval) {
                    ForEach(Configuration.quotaIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) 秒").tag(interval)
                    }
                }
            } header: { Text("面板打开时") }
            footer: { Text("额度快照读取 sub2api 已有数据。关闭面板后，所有自动刷新停止。") }

            Section {
                LabeledContent("完整额度与窗口统计", value: "至少间隔 10 分钟")
            } header: { Text("高成本查询") }
            footer: {
                Text("OpenAI 主动额度接口可能访问上游。首次打开时查询，之后每账号至少间隔 10 分钟；手动刷新和重新打开面板不会绕过限制。窗口计费和周额度估算保留最近一次完整采样，不能视为每 5 秒更新。")
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
