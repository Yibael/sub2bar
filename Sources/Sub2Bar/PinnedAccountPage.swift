import SwiftUI
import Sub2BarCore

@MainActor
final class PinnedAccountNavigation: ObservableObject {
    @Published private(set) var selectedID: Int?
    func select(_ id: Int?) {
        guard id != selectedID else { return }
        selectedID = id
    }
}

/// Observe navigation locally. A page switch must not invalidate the expensive
/// all-account summaries, trigger network work, or wait for outstanding requests.
struct PinnedAccountPage: View {
    @ObservedObject var store: AppStore
    @ObservedObject var navigation: PinnedAccountNavigation

    var body: some View {
        let id = navigation.selectedID
        if let snapshot = store.snapshots.first(where: { $0.id == id }) {
            AccountCard(snapshot: snapshot,
                        stale: store.accountReadError(for: snapshot.id) != nil,
                        isPanelVisible: store.isPanelVisible,
                        todayCost: store.todayStats[snapshot.id]?.standardCost,
                        todayStats: store.todayStats[snapshot.id],
                        todayUsageError: store.todayUsageErrors[snapshot.id],
                        accountReadError: store.accountReadError(for: snapshot.id),
                        accountUpdatedAt: store.accountUpdatedAt[snapshot.id],
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
        } else if let id, let error = store.accountReadError(for: id) {
            AccountUnavailableCard(accountID: id, name: store.availableAccounts.first { $0.id == id }?.name,
                                   error: error, onSwitchAccount: store.selectAdjacentPinned)
                .id(id)
        } else {
            AccountLoadingPlaceholder(isLoading: store.isLoadingInitialAccounts || store.isRefreshing, accountID: id)
        }
    }
}

struct AccountUnavailableCard: View {
    let accountID: Int
    var name: String? = nil
    let error: String
    var onSwitchAccount: ((Int) -> Void)? = nil
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text(name ?? "账号 #\(accountID)").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(expanded ? "收起账号详情" : "展开账号详情")
            Text("账号信息暂不可用").font(.system(size: 10)).foregroundStyle(.secondary).help(error)
            if expanded {
                Divider()
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
        .frame(minHeight: PanelSizing.accountCardHeight, alignment: .topLeading)
        .insetSurface(cornerRadius: 9).opacity(0.65)
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard !expanded, abs(value.translation.width) > 50,
                  abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
            onSwitchAccount?(value.translation.width < 0 ? 1 : -1)
        })
    }
}

struct PinnedAccountNavigationControls: View {
    @ObservedObject var store: AppStore
    @ObservedObject var navigation: PinnedAccountNavigation

    var body: some View {
        let index = navigation.selectedID.flatMap { store.pinnedIDs.firstIndex(of: $0) } ?? 0
        HStack(spacing: 3) {
            Button { store.selectAdjacentPinned(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("上一个 Pin 账号").accessibilityLabel("上一个 Pin 账号")
            Text("\(index + 1) / \(store.pinCount)")
                .font(.system(size: 10, weight: .medium)).monospacedDigit().fixedSize()
                .accessibilityLabel("第 \(index + 1) 个，共 \(store.pinCount) 个 Pin 账号")
            Button { store.selectAdjacentPinned(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("下一个 Pin 账号").accessibilityLabel("下一个 Pin 账号")
        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
    }
}
