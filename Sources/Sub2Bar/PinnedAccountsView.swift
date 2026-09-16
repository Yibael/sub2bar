import SwiftUI
import Sub2BarCore

struct PinnedAccountsView: View {
    @ObservedObject var store: AppStore
    let configure: () -> Void
    @State private var search = ""

    private var filtered: [Account] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.availableAccounts.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
            $0.platformLabel.localizedCaseInsensitiveContains(query) || String($0.id).contains(query)
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
            Text("仅刷新已 Pin 账号。关闭菜单栏面板后停止请求。")
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
                    Text("Pin 自动保存")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if let date = store.accountsUpdatedAt {
                    Text("列表更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var emptyLabel: String {
        if store.isLoadingAccounts { return "正在获取全部账号…" }
        if !store.hasLoadedAccounts { return "点击“获取全部账号”重试" }
        return store.availableAccounts.isEmpty ? "服务器中暂无账号" : "没有匹配的账号"
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 12) {
            Text(String(account.platformLabel.prefix(1)))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30).insetSurface(cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(account.platformLabel) · #\(account.id) · \(account.stateLabel(at: Date()))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { store.setPinned(!store.isPinned(account.id), id: account.id) } label: {
                Label(store.isPinned(account.id) ? "已 Pin" : "Pin", systemImage: store.isPinned(account.id) ? "pin.fill" : "pin")
                    .frame(width: 58)
            }
            .buttonStyle(NeutralButtonStyle(store.isPinned(account.id) ? .primary : .outline))
            .accessibilityLabel("\(store.isPinned(account.id) ? "取消 Pin" : "Pin") \(account.name)")
            .accessibilityValue(store.isPinned(account.id) ? "已 Pin" : "未 Pin")
        }.padding(.vertical, 12)
    }
}
