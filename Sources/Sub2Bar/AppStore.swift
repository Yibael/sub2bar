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
    @Published private(set) var pinnedAccountErrors: [Int: String] = [:]
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
    private var latestAccounts: [Int: Account] = [:]
    private var batchUsageSupported = true
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

    init(defaults: UserDefaults = .standard, credentials: CredentialSession? = nil,
         now: @escaping () -> Date = Date.init, automaticallySchedule: Bool = true,
         clientFactory: @escaping ClientFactory = { APIClient(configuration: $0, key: $1) }) {
        self.defaults = defaults; self.credentials = credentials ?? CredentialSession()
        self.clientFactory = clientFactory; self.now = now; self.automaticallySchedule = automaticallySchedule
        configuration = defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        pinSelection = defaults.data(forKey: pinsKey).flatMap { try? JSONDecoder().decode(PinnedAccountSelection.self, from: $0) } ?? PinnedAccountSelection()
        restorePins()
    }
    var isConfigured: Bool { !configuration.serverURL.isEmpty }
    var hostLabel: String { (try? configuration.baseURL().host) ?? "未配置服务器" }
    var pinCount: Int { pinnedIDs.count }
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
    var warningCount: Int { snapshots.filter { !$0.account.isAvailable || ($0.weeklyPercentage ?? 0) >= 90 || $0.usageError != nil }.count + pinnedAccountErrors.count }
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
        let sameConnection = (try? configuration.baseURL().absoluteString) == base.absoluteString &&
            cachedKey() == key.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasPolling = canPoll
        isSaving = true
        defer { isSaving = false; credentialRevision += 1; updateQuotaDeadline(); scheduleWake() }
        var saved = draft
        saved.serverURL = base.absoluteString; saved.refreshInterval = draft.effectiveRefreshInterval
        saved.accountRefreshInterval = draft.effectiveAccountRefreshInterval
        let data = try JSONEncoder().encode(saved)
        try await credentials.save(key, for: base.absoluteString)
        if sameConnection {
            guard saved != configuration else { return }
            // Timing-only changes keep snapshots, full statistics, pins and the
            // account directory. Save never dispatches a connection request.
            cancelPolling()
            configuration = saved; defaults.set(data, forKey: defaultsKey)
            if wasPolling {
                nextRuntimeAt = now().addingTimeInterval(runtimeDelay)
            }
            return
        }
        resetAllRequests()
        configuration = saved; defaults.set(data, forKey: defaultsKey)
        credentialAttemptedServer = base.absoluteString; credentialError = nil
        restorePins()
        snapshots = []; latestAccounts = [:]; pinnedAccountErrors = [:]
        availableAccounts = []; hasLoadedAccounts = false; accountsError = nil; accountsUpdatedAt = nil
        lastUpdated = nil; quotaUpdatedAt = nil; statusUpdatedAt = nil; errorMessage = nil
        platform = "全部"; search = ""
        batchUsageSupported = true; runtimeFailures = 0
        // Saving does not connect or query; only a subsequent panel opening does.
        requiresReopen = true
    }
    private func restorePins() {
        pinnedIDs = (try? configuration.baseURL().absoluteString).map { pinSelection.ids(for: $0) } ?? []
        if !showsAccountFilters { search = ""; platform = "全部" }
    }
    func isPinned(_ id: Int) -> Bool { pinnedIDs.contains(id) }
    func setPinned(_ pinned: Bool, id: Int) {
        guard id > 0, let server = try? configuration.baseURL().absoluteString else { return }
        pinSelection.setPinned(pinned, id: id, server: server)
        if let data = try? JSONEncoder().encode(pinSelection) { defaults.set(data, forKey: pinsKey) }
        restorePins(); cancelPolling()
        snapshots.removeAll { !pinnedIDs.contains($0.id) }
        latestAccounts = latestAccounts.filter { pinnedIDs.contains($0.key) }
        pinnedAccountErrors = pinnedAccountErrors.filter { pinnedIDs.contains($0.key) }
        if !platforms.contains(platform) { platform = "全部" }
        refresh()
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
    /// Two independent request lanes: account state and quota/statistics.
    func runDueRefreshes() {
        guard canPoll else { return }
        let date = now()
        updateQuotaDeadline()
        let runtimeDue = nextRuntimeAt.map { $0 <= date } ?? true
        if !isRefreshing && runtimeDue { refreshRuntime() }
        if quotaTask == nil, let nextRefreshAt, nextRefreshAt <= date { refreshQuota() }
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
                    nextRuntimeAt = now().addingTimeInterval(runtimeDelay)
                    runDueRefreshes()
                }
            }
            do {
                let result = try await client(for: config).loadPinnedAccounts(ids: ids)
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
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                runtimeFailures = min(runtimeFailures + 1, 5); errorMessage = error.localizedDescription
                handleAuthenticationFailure(error)
            }
        }
    }
    private func refreshQuota() {
        guard canPoll, quotaTask == nil,
              let server = try? configuration.baseURL().absoluteString else { return }
        let token = generation; let config = configuration
        let date = now()
        let accounts = pinnedIDs.filter { quotaDeadline(server: server, id: $0) <= date }
            .compactMap { latestAccounts[$0] }
        guard !accounts.isEmpty else { return }
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
