import AppKit
import SwiftUI
import Sub2BarCore

enum ConnectionState: String {
    case notConfigured = "待配置"
    case disconnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
    case failed = "连接异常"

    var symbol: String {
        switch self {
        case .notConfigured, .disconnected: return "circle"
        case .connecting: return "circle.dotted"
        case .connected: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    typealias ClientFactory = (Configuration, String) -> APIClient
    @Published private(set) var configuration: Configuration
    @Published private(set) var snapshots: [AccountSnapshot] = []
    @Published private(set) var pinnedIDs: [Int] = []
    @Published private(set) var selectedPinnedID: Int?
    @Published private(set) var pinnedAccountErrors: [Int: String] = [:]
    @Published private(set) var todayUsage: [Int: Double] = [:]
    @Published private(set) var todayUsageErrors: [Int: String] = [:]
    @Published private(set) var subscriptions: [Int: AccountSubscription] = [:]
    @Published private(set) var subscriptionUsage: [Int: SubscriptionUsageSample] = [:]
    @Published private(set) var subscriptionErrors: [Int: String] = [:]
    @Published private(set) var todayActualUsage: [Int: TodayActualUsageSample] = [:]
    @Published private(set) var todayActualErrors: [Int: String] = [:]
    @Published private(set) var isRefreshingSubscriptions = false
    @Published private(set) var nextSubscriptionAt: Date?
    @Published private(set) var availableAccounts: [Account] = []
    @Published private(set) var isLoadingAccounts = false
    @Published private(set) var hasLoadedAccounts = false
    @Published private(set) var accountsError: String?
    @Published private(set) var accountsUpdatedAt: Date?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var statusUpdatedAt: Date?
    @Published private(set) var quotaUpdatedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var credentialError: String?
    @Published private(set) var isLoadingCredential = false
    @Published private(set) var isSaving = false
    @Published private(set) var isPanelVisible = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingQuota = false { didSet { updateQuotaLoading() } }
    @Published private(set) var showsQuotaLoading = false
    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var nextRuntimeAt: Date?
    @Published private var credentialRevision = 0
    @Published var search = ""
    @Published var platform = "全部"
    private let defaults: UserDefaults
    private let credentials: CredentialSession
    private let clientFactory: ClientFactory
    private let now: () -> Date
    private let automaticallySchedule: Bool
    private var pinSelection: PinnedAccountSelection
    private var subscriptionPreferences: SubscriptionPreferences
    private var subscriptionTask: Task<Void, Never>?
    private var subscriptionGeneration = UUID()
    private var subscriptionFailures = 0
    private var subscriptionCompletedAt: Date?
    private var subscriptionRetryNotBefore: Date?
    private var runtimeCompletedAt: Date?
    private var latestAccounts: [Int: Account] = [:]
    private var batchUsageSupported = true
    private var manualQuotaRefreshPending = false
    private var runtimeTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var quotaLoadingTask: Task<Void, Never>?
    private var quotaLoadingStartedAt: ContinuousClock.Instant?
    private var accountsTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var credentialAttemptedServer: String?
    private var generation = UUID()
    private var accountsGeneration = UUID()
    private var isSuspended = false
    private var requiresReopen = false
    private var runtimeFailures = 0
    private struct QuotaKey: Hashable {
        let server: String
        let accountID: Int
    }
    private struct QuotaTiming {
        let completedAt: Date
        let failures: Int
        let retryNotBefore: Date?
    }
    // Session-local eligibility survives panel, settings and Pin changes.
    // It contains no credentials or account payloads.
    private var quotaTimings: [QuotaKey: QuotaTiming] = [:]
    private let defaultsKey = "sub2bar.configuration.v1"
    private let pinsKey = "sub2bar.pins.v1"
    private let subscriptionsKey = "sub2bar.subscriptions.v1"
    private static let accountsCacheLifetime: TimeInterval = 60

    init(defaults: UserDefaults = .standard, credentials: CredentialSession? = nil,
         now: @escaping () -> Date = Date.init, automaticallySchedule: Bool = true,
         clientFactory: @escaping ClientFactory = { APIClient(configuration: $0, key: $1) }) {
        self.defaults = defaults; self.credentials = credentials ?? CredentialSession()
        self.clientFactory = clientFactory; self.now = now; self.automaticallySchedule = automaticallySchedule
        configuration = defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        pinSelection = defaults.data(forKey: pinsKey).flatMap { try? JSONDecoder().decode(PinnedAccountSelection.self, from: $0) } ?? PinnedAccountSelection()
        subscriptionPreferences = defaults.data(forKey: subscriptionsKey)
            .flatMap { try? JSONDecoder().decode(SubscriptionPreferences.self, from: $0) } ?? SubscriptionPreferences()
        restorePins()
        restoreSubscriptions()
    }
    var isConfigured: Bool { !configuration.serverURL.isEmpty }
    var hostLabel: String { (try? configuration.baseURL().host) ?? "未配置服务器" }
    var pinCount: Int { pinnedIDs.count }
    var selectedPinnedIndex: Int? { selectedPinnedID.flatMap { pinnedIDs.firstIndex(of: $0) } }
    var selectedPinnedSnapshot: AccountSnapshot? { snapshots.first { $0.id == selectedPinnedID } }
    // Changes only when the saved connection/authentication scope changes.
    var accountDirectoryIdentity: UUID { accountsGeneration }
    var hasFreshAccountDirectory: Bool {
        guard hasLoadedAccounts, let accountsUpdatedAt else { return false }
        let age = now().timeIntervalSince(accountsUpdatedAt)
        return age >= 0 && age < Self.accountsCacheLifetime
    }
    var orderedAvailableAccounts: [Account] {
        let positions = Dictionary(uniqueKeysWithValues: pinnedIDs.enumerated().map { ($0.element, $0.offset) })
        return availableAccounts.sorted {
            let left = positions[$0.id] ?? Int.max, right = positions[$1.id] ?? Int.max
            if left != right { return left < right }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    var showsAccountFilters: Bool { pinCount > 5 }
    var needsCredentialAccess: Bool { isConfigured && cachedKey() == nil }
    var isPolling: Bool { pollTask != nil }
    /// Header feedback belongs to quota work, not the frequent runtime polls.
    var isRefreshingUsage: Bool { isRefreshingQuota }
    var connectionState: ConnectionState {
        guard isConfigured else { return .notConfigured }
        if errorMessage != nil { return .failed }
        if isPanelVisible && isLoadingCredential { return .connecting }
        guard !needsCredentialAccess else { return .notConfigured }
        guard canPoll else { return .disconnected }
        // Keep the last successful connection state during ordinary polling.
        // An upstream quota failure is not a failed connection to sub2api.
        if lastUpdated != nil { return .connected }
        return isRefreshing ? .connecting : .disconnected
    }
    var canPoll: Bool { isPanelVisible && !isSuspended && !requiresReopen && !isSaving && isConfigured && !needsCredentialAccess && !pinnedIDs.isEmpty }
    var platforms: [String] { ["全部"] + Set(snapshots.map(\.account.platformLabel)).sorted() }
    var filtered: [AccountSnapshot] {
        guard showsAccountFilters else { return snapshots }
        return snapshots.filter { (platform == "全部" || $0.account.platformLabel == platform) &&
            (search.isEmpty || $0.account.name.localizedCaseInsensitiveContains(search) || $0.account.platformLabel.localizedCaseInsensitiveContains(search)) }
    }
    var activeCount: Int { snapshots.filter { $0.account.isAvailable && pinnedAccountErrors[$0.id] == nil }.count }
    var concurrency: Int? {
        guard pinnedAccountErrors.isEmpty, snapshots.count == pinCount, !snapshots.isEmpty, snapshots.allSatisfy({ $0.account.currentConcurrency != nil }) else { return nil }
        return snapshots.reduce(0) { $0 + ($1.account.currentConcurrency ?? 0) }
    }
    var concurrencyLimit: Int? {
        guard pinnedAccountErrors.isEmpty, snapshots.count == pinCount, !snapshots.isEmpty, snapshots.allSatisfy({ $0.account.concurrency != nil }) else { return nil }
        return snapshots.reduce(0) { $0 + ($1.account.concurrency ?? 0) }
    }
    var estimatedAccounts: [AccountSnapshot] { snapshots.filter { $0.estimatedWeeklyCost != nil && pinnedAccountErrors[$0.id] == nil } }
    var estimatedTotal: Double? { estimatedAccounts.isEmpty ? nil : estimatedAccounts.compactMap(\.estimatedWeeklyCost).reduce(0, +) }
    var partialErrors: Int { snapshots.filter { $0.usageError != nil }.count + pinnedAccountErrors.count }
    var accountOverview: PinnedAccountOverview {
        PinnedAccountOverview(ids: pinnedIDs, snapshots: snapshots,
                              failedIDs: Set(pinnedAccountErrors.keys), stale: errorMessage != nil, at: now())
    }
    var eligibleSubscriptionIDs: [Int] {
        pinnedIDs.filter { id in
            guard subscriptions[id]?.isComplete == true else { return false }
            // Saved metadata was validated as OAuth. Unknown/failed accounts
            // remain in the denominator until their type can be confirmed.
            let account = latestAccounts[id] ?? snapshots.first { $0.id == id }?.account ?? availableAccounts.first { $0.id == id }
            return account?.supportsSubscription ?? true
        }
    }
    var totalSubscriptionCost: Decimal? {
        guard !eligibleSubscriptionIDs.isEmpty else { return nil }
        return eligibleSubscriptionIDs.compactMap { subscriptions[$0]?.monthlyPrice }.reduce(0, +)
    }
    var totalSubscriptionActualCost: Decimal? {
        let ids = eligibleSubscriptionIDs
        guard !ids.isEmpty else { return nil }
        let costs = ids.compactMap { subscriptionSample(for: $0)?.actualCost }
        guard costs.count == ids.count else { return nil }
        return costs.reduce(0, +)
    }
    var totalTodayActualCost: Decimal? {
        let ids = eligibleSubscriptionIDs
        guard !ids.isEmpty else { return nil }
        let costs = ids.compactMap { todayActualSample(for: $0)?.actualCost }
        guard costs.count == ids.count else { return nil }
        return costs.reduce(0, +)
    }
    func todayActualSample(for id: Int) -> TodayActualUsageSample? {
        guard eligibleSubscriptionIDs.contains(id), pinnedAccountErrors[id] == nil,
              todayActualErrors[id] == nil, let sample = todayActualUsage[id],
              let cycle = subscriptionCycle(for: id), sample.day == cycle.dateString(now()),
              sample.timeZoneID == configuration.subscriptionTimeZoneID,
              sample.includesAdmin == configuration.includeAdminUsage else { return nil }
        return sample
    }
    func subscriptionCycle(for id: Int) -> SubscriptionCycle? {
        guard let value = subscriptions[id], value.isComplete, let day = value.renewalDay else { return nil }
        return SubscriptionCycle(renewalDay: day, at: now(), timeZoneID: configuration.subscriptionTimeZoneID)
    }
    func subscriptionSample(for id: Int) -> SubscriptionUsageSample? {
        guard eligibleSubscriptionIDs.contains(id), pinnedAccountErrors[id] == nil,
              subscriptionErrors[id] == nil, let sample = subscriptionUsage[id],
              sample.cycle == subscriptionCycle(for: id), sample.includesAdmin == configuration.includeAdminUsage else { return nil }
        return sample
    }
    private func restoreSubscriptions() {
        subscriptions = (try? configuration.baseURL().absoluteString)
            .map { subscriptionPreferences.subscriptions(for: $0) } ?? [:]
    }
    func saveSubscription(_ value: AccountSubscription?, for account: Account) throws {
        guard account.supportsSubscription else { throw SubscriptionError.unsupportedAccount }
        if let price = value?.monthlyPrice, price.isNaN || price < 0 { throw SubscriptionError.invalidConfiguration }
        if let day = value?.renewalDay, !(1...31).contains(day) { throw SubscriptionError.invalidConfiguration }
        let server = try configuration.baseURL().absoluteString
        var saved = subscriptionPreferences
        saved.set(value, id: account.id, server: server)
        let data = try JSONEncoder().encode(saved)
        defaults.set(data, forKey: subscriptionsKey)
        subscriptionPreferences = saved; restoreSubscriptions()
        cancelSubscriptionPolling()
        subscriptionUsage[account.id] = nil; subscriptionErrors[account.id] = nil
        todayActualUsage[account.id] = nil; todayActualErrors[account.id] = nil
        nextSubscriptionAt = now(); subscriptionFailures = 0
        subscriptionCompletedAt = nil; subscriptionRetryNotBefore = nil
        if canPoll { runDueRefreshes() }
    }
    func cachedKey(for config: Configuration? = nil) -> String? {
        guard let server = try? (config ?? configuration).baseURL().absoluteString else { return nil }
        return credentials.cachedKey(for: server)
    }
    func start() { Task { await prepareCredentials() } }

    /// Read the local file once per configured server per process. No Keychain.
    func prepareCredentials() async {
        if let task = credentialTask { await task.value; return }
        guard let server = try? configuration.baseURL().absoluteString, cachedKey() == nil,
              credentialAttemptedServer != server else { return }
        credentialAttemptedServer = server
        isLoadingCredential = true
        let task = Task { [self] in
            defer { isLoadingCredential = false; credentialRevision += 1; credentialTask = nil }
            do { _ = try await credentials.load(for: server); credentialError = nil }
            catch {
                credentialError = error is APIError ? "请在设置中重新输入 Admin Key 并保存。旧版钥匙串条目不会自动迁移。" : error.localizedDescription
            }
        }
        credentialTask = task
        await task.value
    }

    func save(_ draft: Configuration, key: String) async throws {
        guard !isSaving, !isLoadingCredential else { throw CredentialSessionError.busy }
        let base = try draft.baseURL()
        guard TimeZone(identifier: draft.subscriptionTimeZoneID) != nil else { throw SubscriptionError.invalidConfiguration }
        let sameConnection = (try? configuration.baseURL().absoluteString) == base.absoluteString &&
            cachedKey() == key.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved = draft
        saved.actualCostCurrency = try CurrencyUnit.normalized(draft.actualCostCurrency)
        saved.subscriptionCostCurrency = try CurrencyUnit.normalized(draft.subscriptionCostCurrency)
        saved.serverURL = base.absoluteString; saved.refreshInterval = draft.effectiveRefreshInterval
        saved.accountRefreshInterval = draft.effectiveAccountRefreshInterval
        saved.statisticsRefreshInterval = draft.effectiveStatisticsRefreshInterval
        let data = try JSONEncoder().encode(saved)
        if sameConnection {
            var localOnly = configuration
            localOnly.actualCostCurrency = saved.actualCostCurrency
            localOnly.subscriptionCostCurrency = saved.subscriptionCostCurrency
            localOnly.refreshInterval = saved.refreshInterval
            localOnly.accountRefreshInterval = saved.accountRefreshInterval
            localOnly.statisticsRefreshInterval = saved.statisticsRefreshInterval
            if localOnly == saved {
                // Independent timing/display edits preserve all running work,
                // cached amounts, and the untouched lanes' deadlines.
                let quotaChanged = configuration.refreshInterval != saved.refreshInterval
                let runtimeChanged = configuration.accountRefreshInterval != saved.accountRefreshInterval
                let statisticsChanged = configuration.statisticsRefreshInterval != saved.statisticsRefreshInterval
                configuration = saved; defaults.set(data, forKey: defaultsKey)
                if quotaChanged { updateQuotaDeadline() }
                if runtimeChanged, canPoll, !isRefreshing {
                    nextRuntimeAt = (runtimeCompletedAt ?? now()).addingTimeInterval(runtimeDelay)
                }
                if statisticsChanged, canPoll, subscriptionTask == nil {
                    nextSubscriptionAt = subscriptionDeadline
                }
                if quotaChanged || runtimeChanged || statisticsChanged { scheduleWake() }
                return
            }
        }
        let wasPolling = canPoll
        isSaving = true
        defer { isSaving = false; credentialRevision += 1; updateQuotaDeadline(); scheduleWake() }
        try await credentials.save(key, for: base.absoluteString)
        if sameConnection {
            let statisticsChanged = saved.includeAdminUsage != configuration.includeAdminUsage ||
                saved.subscriptionTimeZoneID != configuration.subscriptionTimeZoneID
            // Timing-only changes keep snapshots, full statistics, pins and the
            // account directory. Save never dispatches a connection request.
            cancelPolling()
            configuration = saved; defaults.set(data, forKey: defaultsKey)
            if statisticsChanged {
                subscriptionUsage = [:]; subscriptionErrors = [:]; subscriptionFailures = 0
                todayActualUsage = [:]; todayActualErrors = [:]
                subscriptionCompletedAt = nil; subscriptionRetryNotBefore = nil
            }
            if wasPolling {
                nextRuntimeAt = now().addingTimeInterval(runtimeDelay)
                nextSubscriptionAt = now()
            }
            return
        }
        resetAllRequests()
        configuration = saved; defaults.set(data, forKey: defaultsKey)
        credentialAttemptedServer = base.absoluteString; credentialError = nil
        selectedPinnedID = nil
        restorePins()
        restoreSubscriptions()
        subscriptionUsage = [:]; subscriptionErrors = [:]; subscriptionFailures = 0
        todayActualUsage = [:]; todayActualErrors = [:]
        subscriptionCompletedAt = nil; subscriptionRetryNotBefore = nil; runtimeCompletedAt = nil
        snapshots = []; latestAccounts = [:]; pinnedAccountErrors = [:]
        todayUsage = [:]; todayUsageErrors = [:]
        availableAccounts = []; hasLoadedAccounts = false; accountsError = nil; accountsUpdatedAt = nil
        lastUpdated = nil; quotaUpdatedAt = nil; statusUpdatedAt = nil; errorMessage = nil
        platform = "全部"; search = ""
        batchUsageSupported = true; runtimeFailures = 0
        // Saving does not connect or query; only a subsequent panel opening does.
        requiresReopen = true
    }
    private func restorePins() {
        pinnedIDs = (try? configuration.baseURL().absoluteString).map { pinSelection.ids(for: $0) } ?? []
        if selectedPinnedID.map({ pinnedIDs.contains($0) }) != true { selectedPinnedID = pinnedIDs.first }
        if !showsAccountFilters { search = ""; platform = "全部" }
    }
    func isPinned(_ id: Int) -> Bool { pinnedIDs.contains(id) }
    func setPinned(_ pinned: Bool, id: Int) {
        guard id > 0, let server = try? configuration.baseURL().absoluteString else { return }
        let removedSelected = !pinned && selectedPinnedID == id
        let previousIndex = selectedPinnedIndex ?? 0
        pinSelection.setPinned(pinned, id: id, server: server)
        if let data = try? JSONEncoder().encode(pinSelection) { defaults.set(data, forKey: pinsKey) }
        restorePins(); cancelPolling()
        if removedSelected { selectedPinnedID = pinnedIDs.isEmpty ? nil : pinnedIDs[min(previousIndex, pinnedIDs.count - 1)] }
        snapshots.removeAll { !pinnedIDs.contains($0.id) }
        latestAccounts = latestAccounts.filter { pinnedIDs.contains($0.key) }
        pinnedAccountErrors = pinnedAccountErrors.filter { pinnedIDs.contains($0.key) }
        todayUsage = todayUsage.filter { pinnedIDs.contains($0.key) }
        todayUsageErrors = todayUsageErrors.filter { pinnedIDs.contains($0.key) }
        subscriptionUsage = subscriptionUsage.filter { pinnedIDs.contains($0.key) }
        subscriptionErrors = subscriptionErrors.filter { pinnedIDs.contains($0.key) }
        todayActualUsage = todayActualUsage.filter { pinnedIDs.contains($0.key) }
        todayActualErrors = todayActualErrors.filter { pinnedIDs.contains($0.key) }
        if !platforms.contains(platform) { platform = "全部" }
        refresh()
    }
    func selectPinned(_ id: Int) {
        guard pinnedIDs.contains(id) else { return }
        selectedPinnedID = id
    }
    func selectAdjacentPinned(_ direction: Int) {
        guard pinnedIDs.count > 1, [-1, 1].contains(direction), let index = selectedPinnedIndex else { return }
        selectedPinnedID = pinnedIDs[(index + direction + pinnedIDs.count) % pinnedIDs.count]
    }
    func movePinned(_ id: Int, by offset: Int) {
        guard let source = pinnedIDs.firstIndex(of: id), [-1, 1].contains(offset),
              pinnedIDs.indices.contains(source + offset), let server = try? configuration.baseURL().absoluteString else { return }
        pinSelection.move(id: id, to: source + offset, server: server)
        if let data = try? JSONEncoder().encode(pinSelection) { defaults.set(data, forKey: pinsKey) }
        restorePins()
        let order = Dictionary(uniqueKeysWithValues: pinnedIDs.enumerated().map { ($0.element, $0.offset) })
        snapshots.sort { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
        // Reordering/selection changes presentation only: no polling cancellation,
        // new requests, quota cooldown resets, or subscription-statistics changes.
    }
    func loadAvailableAccountsIfNeeded() {
        guard !hasFreshAccountDirectory else { return }
        // Authentication failure must not become an on-appear retry loop.
        guard !(needsCredentialAccess && credentialError != nil) else { return }
        loadAvailableAccounts()
    }
    func loadAvailableAccounts() {
        guard isConfigured, !isLoadingAccounts, !isSaving else { return }
        isLoadingAccounts = true; accountsError = nil
        let token = accountsGeneration; let config = configuration
        accountsTask = Task { [self] in
            defer { if accountsGeneration == token { isLoadingAccounts = false; accountsTask = nil } }
            await prepareCredentials()
            guard !Task.isCancelled, accountsGeneration == token else { return }
            do {
                let items = try await client(for: config).loadAccounts()
                guard !Task.isCancelled, accountsGeneration == token else { return }
                availableAccounts = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                hasLoadedAccounts = true; accountsUpdatedAt = now()
            } catch {
                guard !Task.isCancelled, accountsGeneration == token else { return }
                handleAuthenticationFailure(error); accountsError = error.localizedDescription
            }
        }
    }
    private func client(for config: Configuration) throws -> APIClient {
        clientFactory(config, try credentials.requireCachedKey(for: config.baseURL().absoluteString))
    }
    func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        if !visible { cancelPolling(); return }
        requiresReopen = false
        let token = generation
        Task { [self] in
            await prepareCredentials()
            guard token == generation, isPanelVisible else { return }
            refresh()
        }
    }
    func suspendForSleep() { isSuspended = true; cancelPolling() }
    func resumeAfterSleep() { isSuspended = false; refresh() }
    func refresh() {
        guard canPoll else { return }
        let date = now()
        if !isRefreshing { nextRuntimeAt = date }
        runDueRefreshes()
    }
    /// Explicit button action: bypass only the local timer/backoff, never send
    /// force=true to sub2api. Coalesce clicks with any existing quota request.
    func refreshManually() {
        guard canPoll, quotaTask == nil else { return }
        manualQuotaRefreshPending = true
        if subscriptionTask == nil { nextSubscriptionAt = now() }
        refresh()
    }
    /// Independent lanes: account state/daily usage, quota/windows, and subscription consumption.
    func runDueRefreshes() {
        guard canPoll else { return }
        let date = now()
        updateQuotaDeadline()
        let runtimeDue = nextRuntimeAt.map { $0 <= date } ?? true
        if !isRefreshing && runtimeDue { refreshRuntime() }
        if quotaTask == nil, manualQuotaRefreshPending || (nextRefreshAt.map { $0 <= date } ?? false) {
            refreshQuota(ignoringSchedule: manualQuotaRefreshPending)
        }
        if subscriptionTask == nil, nextSubscriptionAt.map({ $0 <= date }) ?? true { refreshSubscriptions() }
        scheduleWake()
    }
    private var runtimeDelay: Double {
        min(120, configuration.effectiveAccountRefreshInterval * pow(2, Double(runtimeFailures)))
    }
    private func quotaDeadline(server: String, id: Int) -> Date {
        guard let timing = quotaTimings[QuotaKey(server: server, accountID: id)] else { return .distantPast }
        let delay = min(600, configuration.effectiveRefreshInterval * pow(2, Double(timing.failures)))
        let deadline = timing.completedAt.addingTimeInterval(delay)
        return max(deadline, timing.retryNotBefore ?? deadline)
    }
    private func updateQuotaDeadline() {
        guard canPoll, let server = try? configuration.baseURL().absoluteString else {
            nextRefreshAt = nil
            return
        }
        nextRefreshAt = pinnedIDs.filter { latestAccounts[$0] != nil }
            .map { quotaDeadline(server: server, id: $0) }.min()
    }
    private func refreshRuntime() {
        guard canPoll, !isRefreshing else { return }
        isRefreshing = true
        let token = generation; let config = configuration; let ids = pinnedIDs
        runtimeTask = Task { [self] in
            defer {
                if generation == token {
                    isRefreshing = false; runtimeTask = nil
                    runtimeCompletedAt = now()
                    nextRuntimeAt = runtimeCompletedAt?.addingTimeInterval(runtimeDelay)
                    runDueRefreshes()
                }
            }
            do {
                let api = try client(for: config)
                async let dailyCosts = api.loadTodayUsageBatch(ids: ids)
                let result = try await api.loadPinnedAccounts(ids: ids)
                guard generation == token, !Task.isCancelled, canPoll else { return }
                runtimeFailures = result.accountErrors.isEmpty ? 0 : min(runtimeFailures + 1, 5)
                pinnedAccountErrors = result.accountErrors
                for item in result.snapshots {
                    let old = snapshots.first { $0.id == item.id }
                    latestAccounts[item.id] = item.account
                    replace(AccountSnapshot(account: item.account, usage: old?.usage, usageError: old?.usageError,
                                            statisticsUsage: old?.statisticsUsage, statisticsUpdatedAt: old?.statisticsUpdatedAt))
                }
                for id in result.accountErrors.keys { latestAccounts[id] = nil }
                if result.snapshots.isEmpty && !result.accountErrors.isEmpty { errorMessage = "账号读取失败，显示上次结果。" }
                else { lastUpdated = now(); errorMessage = nil }
                statusUpdatedAt = now()
                if !platforms.contains(platform) { platform = "全部" }
                // Start eligible quota work without waiting for daily statistics.
                runDueRefreshes()
                do {
                    let costs = try await dailyCosts
                    guard generation == token, !Task.isCancelled, canPoll else { return }
                    todayUsage = costs
                    todayUsageErrors = Dictionary(uniqueKeysWithValues: ids.filter { costs[$0] == nil }
                        .map { ($0, "今日用量暂不可用") })
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    todayUsage = [:]
                    todayUsageErrors = Dictionary(uniqueKeysWithValues: ids.map { ($0, "今日用量读取失败") })
                    handleAuthenticationFailure(error)
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                todayUsage = [:]
                todayUsageErrors = Dictionary(uniqueKeysWithValues: ids.map { ($0, "今日用量读取失败") })
                runtimeFailures = min(runtimeFailures + 1, 5); errorMessage = error.localizedDescription
                handleAuthenticationFailure(error)
            }
        }
    }
    private func refreshQuota(ignoringSchedule: Bool = false) {
        guard canPoll, quotaTask == nil,
              let server = try? configuration.baseURL().absoluteString else { return }
        let token = generation; let config = configuration
        let date = now()
        let accounts = pinnedIDs.filter { ignoringSchedule || quotaDeadline(server: server, id: $0) <= date }
            .compactMap { latestAccounts[$0] }
        guard !accounts.isEmpty else { return }
        // If account details were not loaded yet, retain the pending intent
        // until refreshRuntime can supply them. Cancellation clears it.
        manualQuotaRefreshPending = false
        isRefreshingQuota = true
        quotaTask = Task { [self] in
            var attempted = false
            var failures: [Int: Bool] = [:]
            defer {
                // Cancellation also completes an attempt: the server may have
                // received it already. Record even when UI generation changed.
                if attempted {
                    let completedAt = now()
                    for account in accounts {
                        let key = QuotaKey(server: server, accountID: account.id)
                        let previous = quotaTimings[key]
                        let count = failures[account.id].map { $0 ? min((previous?.failures ?? 0) + 1, 4) : 0 }
                            ?? previous?.failures ?? 0
                        let retry = count == 0 ? nil : completedAt.addingTimeInterval(
                            min(600, config.effectiveRefreshInterval * pow(2, Double(count))))
                        quotaTimings[key] = QuotaTiming(completedAt: completedAt, failures: count,
                                                       retryNotBefore: retry)
                    }
                }
                quotaTask = nil
                if generation == token {
                    isRefreshingQuota = false
                }
                updateQuotaDeadline(); scheduleWake()
            }
            do {
                try Task.checkCancellation()
                let api = try client(for: config)
                attempted = true
                let results: [AccountUsageResult]
                if batchUsageSupported {
                    do {
                        results = try await api.loadUsageBatch(ids: accounts.map(\.id))
                    } catch let error as APIError where error == .http(404) || error == .http(405) {
                        guard generation == token, !Task.isCancelled, canPoll else { return }
                        batchUsageSupported = false
                        results = try await loadIndividualUsage(accounts: accounts, api: api)
                    }
                } else {
                    results = try await loadIndividualUsage(accounts: accounts, api: api)
                }
                guard generation == token, !Task.isCancelled, canPoll else { return }
                for result in results { failures[result.id] = result.error != nil }
                applyUsage(results)
                if results.contains(where: { $0.usage != nil }) { quotaUpdatedAt = now() }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                for account in accounts { failures[account.id] = true }
                applyUsage(accounts.map { AccountUsageResult(id: $0.id, usage: nil, error: "额度读取失败") })
                handleAuthenticationFailure(error)
            }
        }
    }
    private func loadIndividualUsage(accounts: [Account], api: APIClient) async throws -> [AccountUsageResult] {
        try await withThrowingTaskGroup(of: AccountUsageResult.self) { group in
            var iterator = accounts.makeIterator()
            func enqueue(_ account: Account) {
                group.addTask {
                    do {
                        let usage = try await api.loadUsage(for: account, passive: account.supportsPassiveUsage)
                        return AccountUsageResult(id: account.id, usage: usage.hasError ? nil : usage,
                                                  error: usage.hasError ? "额度读取失败" : nil)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if let e = error as? APIError, e == .http(401) || e == .http(403) { throw e }
                        return AccountUsageResult(id: account.id, usage: nil, error: "额度读取失败")
                    }
                }
            }
            for _ in 0..<4 { if let account = iterator.next() { enqueue(account) } }
            var results: [AccountUsageResult] = []
            for try await result in group {
                try Task.checkCancellation(); results.append(result)
                if let next = iterator.next() { enqueue(next) }
            }
            return results
        }
    }
    private func applyUsage(_ results: [AccountUsageResult]) {
        for result in results {
            guard let old = snapshots.first(where: { $0.id == result.id }) else { continue }
            // Percentage, reset time and cost always come from one response.
            // Failures retain the last complete response instead of blanking it.
            replace(AccountSnapshot(account: old.account, usage: result.usage ?? old.usage, usageError: result.error,
                                    statisticsUsage: result.usage ?? old.statisticsUsage,
                                    statisticsUpdatedAt: result.usage == nil ? old.statisticsUpdatedAt : now()))
        }
    }
    private func replace(_ item: AccountSnapshot) {
        guard pinnedIDs.contains(item.id) else { return }
        snapshots.removeAll { $0.id == item.id }; snapshots.append(item)
        snapshots.sort { (pinnedIDs.firstIndex(of: $0.id) ?? 0) < (pinnedIDs.firstIndex(of: $1.id) ?? 0) }
    }
    private var subscriptionRequests: [SubscriptionUsageRequest] {
        eligibleSubscriptionIDs.compactMap { id in
            guard latestAccounts[id]?.supportsSubscription == true, let cycle = subscriptionCycle(for: id) else { return nil }
            return SubscriptionUsageRequest(accountID: id, cycle: cycle)
        }
    }
    private var subscriptionDelay: TimeInterval {
        min(600, configuration.effectiveStatisticsRefreshInterval * pow(2, Double(subscriptionFailures)))
    }
    private var subscriptionDeadline: Date {
        guard let completed = subscriptionCompletedAt else { return now() }
        return max(completed.addingTimeInterval(subscriptionDelay), subscriptionRetryNotBefore ?? .distantPast)
    }
    private func refreshSubscriptions() {
        guard canPoll, subscriptionTask == nil else { return }
        let requests = subscriptionRequests
        guard !requests.isEmpty else { return }
        let token = subscriptionGeneration; let config = configuration; let date = now()
        isRefreshingSubscriptions = true
        subscriptionTask = Task { [self] in
            defer {
                if token == subscriptionGeneration {
                    subscriptionTask = nil; isRefreshingSubscriptions = false
                    subscriptionCompletedAt = now()
                    subscriptionRetryNotBefore = subscriptionFailures > 0 ? now().addingTimeInterval(subscriptionDelay) : nil
                    nextSubscriptionAt = subscriptionDeadline
                    scheduleWake()
                }
            }
            do {
                let results = try await client(for: config).loadSubscriptionUsage(requests, includeAdmin: config.includeAdminUsage, at: date, includeToday: true)
                guard token == subscriptionGeneration, !Task.isCancelled, canPoll else { return }
                subscriptionFailures = results.contains { $0.error != nil || $0.todayError != nil } ? min(subscriptionFailures + 1, 5) : 0
                for result in results {
                    let id = result.request.accountID
                    guard eligibleSubscriptionIDs.contains(id), result.request.cycle == subscriptionCycle(for: id) else {
                        subscriptionUsage[id] = nil
                        todayActualUsage[id] = nil
                        continue
                    }
                    if let cost = result.actualCost {
                        subscriptionUsage[id] = SubscriptionUsageSample(cycle: result.request.cycle, actualCost: cost,
                            includesAdmin: config.includeAdminUsage, sampledAt: now())
                        subscriptionErrors[id] = nil
                    } else {
                        subscriptionUsage[id] = nil; subscriptionErrors[id] = result.error ?? "订阅消费读取失败"
                    }
                    if result.request.cycle.dateString(date) != result.request.cycle.dateString(now()) {
                        todayActualUsage[id] = nil
                    } else if let cost = result.todayActualCost {
                        todayActualUsage[id] = TodayActualUsageSample(day: result.request.cycle.dateString(date),
                            timeZoneID: config.subscriptionTimeZoneID, actualCost: cost,
                            includesAdmin: config.includeAdminUsage, sampledAt: now())
                        todayActualErrors[id] = nil
                    } else {
                        todayActualUsage[id] = nil; todayActualErrors[id] = result.todayError ?? "今日实际消费读取失败"
                    }
                }
            } catch {
                guard token == subscriptionGeneration, !Task.isCancelled else { return }
                subscriptionFailures = min(subscriptionFailures + 1, 5)
                for request in requests {
                    subscriptionUsage[request.accountID] = nil
                    subscriptionErrors[request.accountID] = "订阅消费读取失败，请检查统计接口及 Admin 用户权限。"
                    todayActualUsage[request.accountID] = nil
                    todayActualErrors[request.accountID] = "今日实际消费读取失败，请检查统计接口及 Admin 用户权限。"
                }
                handleAuthenticationFailure(error)
            }
        }
    }
    private func cancelSubscriptionPolling() {
        subscriptionGeneration = UUID()
        subscriptionTask?.cancel(); subscriptionTask = nil
        isRefreshingSubscriptions = false; nextSubscriptionAt = nil
    }
    func secondsUntilRefresh(at date: Date) -> Int? {
        guard canPoll, !isRefreshingQuota, let nextRefreshAt else { return nil }
        return max(0, Int(ceil(nextRefreshAt.timeIntervalSince(date))))
    }
    /// Keep fast quota cycles visible without delaying requests or changing
    /// polling deadlines. A new cycle cancels the previous visual hide task.
    private func updateQuotaLoading() {
        quotaLoadingTask?.cancel(); quotaLoadingTask = nil
        if isRefreshingUsage {
            if !showsQuotaLoading {
                quotaLoadingStartedAt = .now
                showsQuotaLoading = true
            }
            return
        }
        guard showsQuotaLoading, let started = quotaLoadingStartedAt else { return }
        let remaining = Duration.milliseconds(300) - started.duration(to: .now)
        if remaining <= .zero {
            showsQuotaLoading = false; quotaLoadingStartedAt = nil
            return
        }
        quotaLoadingTask = Task { [weak self] in
            do { try await Task.sleep(for: remaining) } catch { return }
            guard let self, !Task.isCancelled, !self.isRefreshingUsage else { return }
            self.showsQuotaLoading = false; self.quotaLoadingStartedAt = nil
            self.quotaLoadingTask = nil
        }
    }
    private func scheduleWake() {
        pollTask?.cancel(); pollTask = nil
        guard automaticallySchedule, canPoll else { return }
        var dates: [Date] = []
        if !isRefreshing, let nextRuntimeAt { dates.append(nextRuntimeAt) }
        if quotaTask == nil, let nextRefreshAt { dates.append(nextRefreshAt) }
        if subscriptionTask == nil, !subscriptionRequests.isEmpty, let nextSubscriptionAt { dates.append(nextSubscriptionAt) }
        guard let next = dates.min() else { return }
        let delay = max(0.05, next.timeIntervalSince(now())); let token = generation
        pollTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.pollTask = nil; self.runDueRefreshes()
        }
    }
    private func cancelPolling() {
        generation = UUID()
        cancelSubscriptionPolling()
        manualQuotaRefreshPending = false
        for task in [runtimeTask, quotaTask, pollTask] { task?.cancel() }
        // Keep the quota task as a lock until its cancellation has completed.
        runtimeTask = nil; pollTask = nil
        isRefreshing = false; isRefreshingQuota = false
        quotaLoadingTask?.cancel(); quotaLoadingTask = nil
        showsQuotaLoading = false; quotaLoadingStartedAt = nil
        nextRuntimeAt = nil; nextRefreshAt = nil
    }
    private func resetAllRequests() {
        cancelPolling(); accountsGeneration = UUID(); accountsTask?.cancel(); accountsTask = nil; isLoadingAccounts = false
    }
    private func handleAuthenticationFailure(_ error: Error) {
        guard let error = error as? APIError, error == .http(401) || error == .http(403) else { return }
        credentials.clear(); credentialRevision += 1
        credentialError = "服务器拒绝了 Admin Key，请在设置中更新。"
        resetAllRequests()
    }
    func openDashboard() {
        guard let base = try? configuration.baseURL() else { return }
        NSWorkspace.shared.open(base.appendingPathComponent("admin/accounts"))
    }
}
