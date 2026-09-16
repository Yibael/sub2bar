import AppKit
import SwiftUI
import Sub2BarCore

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
    @Published private(set) var isRefreshingQuota = false
    @Published private(set) var isRefreshingUpstream = false
    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var nextRuntimeAt: Date?
    @Published private(set) var nextStatusAt: Date?
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
    private var lastHighCostAttempt: [String: Date] = [:]
    private var runtimeTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var upstreamTask: Task<Void, Never>?
    private var accountsTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var credentialAttemptedServer: String?
    private var generation = UUID()
    private var accountsGeneration = UUID()
    private var isSuspended = false
    private var requiresReopen = false
    private var runtimeFailures = 0
    private var quotaFailures = 0
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
    var needsCredentialAccess: Bool { isConfigured && cachedKey() == nil }
    var isPolling: Bool { pollTask != nil }
    var canPoll: Bool { isPanelVisible && !isSuspended && !requiresReopen && !isSaving && isConfigured && !needsCredentialAccess && !pinnedIDs.isEmpty }
    var platforms: [String] { ["全部"] + Set(snapshots.map(\.account.platformLabel)).sorted() }
    var filtered: [AccountSnapshot] {
        snapshots.filter { (platform == "全部" || $0.account.platformLabel == platform) &&
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
        isSaving = true
        defer { isSaving = false; credentialRevision += 1 }
        var saved = draft
        saved.serverURL = base.absoluteString; saved.refreshInterval = draft.effectiveRefreshInterval
        let data = try JSONEncoder().encode(saved)
        try await credentials.save(key, for: base.absoluteString)
        resetAllRequests()
        configuration = saved; defaults.set(data, forKey: defaultsKey)
        credentialAttemptedServer = base.absoluteString; credentialError = nil
        restorePins()
        snapshots = []; latestAccounts = [:]; pinnedAccountErrors = [:]
        availableAccounts = []; hasLoadedAccounts = false; accountsError = nil; accountsUpdatedAt = nil
        lastUpdated = nil; quotaUpdatedAt = nil; statusUpdatedAt = nil; errorMessage = nil
        platform = "全部"; search = ""
        // Saving does not connect or query; only a subsequent panel opening does.
        requiresReopen = true
    }
    private func restorePins() {
        pinnedIDs = (try? configuration.baseURL().absoluteString).map { pinSelection.ids(for: $0) } ?? []
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
        if !isRefreshing { nextRuntimeAt = date; nextStatusAt = date }
        if !isRefreshingQuota { nextRefreshAt = date }
        runDueRefreshes()
    }
    /// Coalesce coincident runtime/status deadlines; high-cost calls run separately.
    func runDueRefreshes() {
        guard canPoll else { return }
        let date = now()
        let runtimeDue = nextRuntimeAt.map { $0 <= date } ?? true
        let statusDue = nextStatusAt.map { $0 <= date } ?? true
        if !isRefreshing && (runtimeDue || statusDue) { refreshRuntime(updateStatus: statusDue) }
        if !isRefreshingQuota && (nextRefreshAt.map { $0 <= date } ?? true), !latestAccounts.isEmpty { refreshCachedQuota() }
        scheduleWake()
    }
    private func refreshRuntime(updateStatus: Bool) {
        guard canPoll, !isRefreshing else { return }
        isRefreshing = true
        let token = generation; let config = configuration; let ids = pinnedIDs
        runtimeTask = Task { [self] in
            defer {
                if generation == token {
                    isRefreshing = false; runtimeTask = nil
                    let interval = min(60, Configuration.concurrencyInterval * pow(2, Double(runtimeFailures)))
                    nextRuntimeAt = now().addingTimeInterval(interval)
                    if updateStatus { nextStatusAt = now().addingTimeInterval(max(Configuration.statusInterval, interval)) }
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
                    let account = updateStatus ? item.account : (old?.account.withRuntime(from: item.account) ?? item.account)
                    replace(AccountSnapshot(account: account, usage: old?.usage, usageError: old?.usageError,
                                            statisticsUsage: old?.statisticsUsage, statisticsUpdatedAt: old?.statisticsUpdatedAt))
                }
                for id in result.accountErrors.keys { latestAccounts[id] = nil }
                if result.snapshots.isEmpty && !result.accountErrors.isEmpty { errorMessage = "账号读取失败，显示上次结果。" }
                else { lastUpdated = now(); errorMessage = nil }
                if updateStatus { statusUpdatedAt = now() }
                if !platforms.contains(platform) { platform = "全部" }
                refreshHighCostIfDue()
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                runtimeFailures = min(runtimeFailures + 1, 5); errorMessage = error.localizedDescription
                handleAuthenticationFailure(error)
            }
        }
    }
    private func refreshCachedQuota() {
        guard canPoll, !isRefreshingQuota else { return }
        isRefreshingQuota = true
        let token = generation; let config = configuration
        let accounts = pinnedIDs.compactMap { latestAccounts[$0] }
        // Fast OpenAI path reads account.extra, never /usage?source=active.
        for account in accounts where account.platform == "openai" {
            guard let old = snapshots.first(where: { $0.id == account.id }) else { continue }
            let cached = account.extra?.usage(at: now())
            let hasCache = cached?.fiveHour != nil || cached?.sevenDay != nil
            replace(AccountSnapshot(account: old.account, usage: hasCache ? cached : old.usage,
                                    usageError: old.usageError, statisticsUsage: old.statisticsUsage,
                                    statisticsUpdatedAt: old.statisticsUpdatedAt))
        }
        let passive = accounts.filter(\.supportsPassiveUsage)
        quotaTask = Task { [self] in
            defer {
                if generation == token {
                    isRefreshingQuota = false; quotaTask = nil; quotaUpdatedAt = now()
                    let delay = min(60, configuration.effectiveRefreshInterval * pow(2, Double(quotaFailures)))
                    nextRefreshAt = now().addingTimeInterval(delay); scheduleWake()
                }
            }
            do {
                let results = try await loadUsage(accounts: passive, api: client(for: config), passive: true)
                guard generation == token, !Task.isCancelled, canPoll else { return }
                quotaFailures = results.contains { $0.error != nil } ? min(quotaFailures + 1, 4) : 0
                applyUsage(results, highCost: false)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                quotaFailures = min(quotaFailures + 1, 4); handleAuthenticationFailure(error)
            }
        }
    }
    /// Reserve BEFORE dispatch. Closing, cancelling, saving, unpin/re-pin and
    /// manual refresh never reset the per-server/account ten-minute budget.
    private func refreshHighCostIfDue() {
        guard canPoll, !isRefreshingUpstream else { return }
        let config = configuration
        guard let server = try? config.baseURL().absoluteString else { return }
        let date = now()
        let accounts = pinnedIDs.compactMap { latestAccounts[$0] }.filter { account in
            guard !account.supportsPassiveUsage else { return false }
            guard let last = lastHighCostAttempt["\(server)|\(account.id)"] else { return true }
            return date.timeIntervalSince(last) >= Configuration.upstreamMinimumInterval
        }
        guard !accounts.isEmpty else { return }
        for account in accounts { lastHighCostAttempt["\(server)|\(account.id)"] = date }
        isRefreshingUpstream = true
        let token = generation
        upstreamTask = Task { [self] in
            defer { if generation == token { isRefreshingUpstream = false; upstreamTask = nil } }
            do {
                let results = try await loadUsage(accounts: accounts, api: client(for: config), passive: false)
                guard generation == token, !Task.isCancelled, canPoll else { return }
                applyUsage(results, highCost: true)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                handleAuthenticationFailure(error)
            }
        }
    }
    private struct UsageResult: Sendable { let id: Int; let usage: UsageInfo?; let error: String? }
    private func loadUsage(accounts: [Account], api: APIClient, passive: Bool) async throws -> [UsageResult] {
        try await withThrowingTaskGroup(of: UsageResult.self) { group in
            var iterator = accounts.makeIterator()
            func enqueue(_ account: Account) {
                group.addTask {
                    do {
                        let usage = try await api.loadUsage(for: account, passive: passive)
                        return UsageResult(id: account.id, usage: usage, error: usage.hasError ? "上游额度暂不可用" : nil)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if let e = error as? APIError, e == .http(401) || e == .http(403) { throw e }
                        return UsageResult(id: account.id, usage: nil, error: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<4 { if let account = iterator.next() { enqueue(account) } }
            var results: [UsageResult] = []
            for try await result in group {
                try Task.checkCancellation(); results.append(result)
                if let next = iterator.next() { enqueue(next) }
            }
            return results
        }
    }
    private func applyUsage(_ results: [UsageResult], highCost: Bool) {
        for result in results {
            guard let old = snapshots.first(where: { $0.id == result.id }) else { continue }
            var display = result.usage ?? old.usage
            if highCost, let sampled = latestAccounts[result.id]?.extra?.sampledAt,
               let returned = result.usage?.updatedAt.flatMap(parseAPIDate), sampled > returned {
                display = latestAccounts[result.id]?.extra?.usage(at: now())
            }
            replace(AccountSnapshot(account: old.account, usage: display, usageError: result.error,
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
    private func scheduleWake() {
        pollTask?.cancel(); pollTask = nil
        guard automaticallySchedule, canPoll else { return }
        var dates: [Date] = []
        if !isRefreshing { dates += [nextRuntimeAt, nextStatusAt].compactMap { $0 } }
        if !isRefreshingQuota, !latestAccounts.isEmpty, let nextRefreshAt { dates.append(nextRefreshAt) }
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
        for task in [runtimeTask, quotaTask, upstreamTask, pollTask] { task?.cancel() }
        runtimeTask = nil; quotaTask = nil; upstreamTask = nil; pollTask = nil
        isRefreshing = false; isRefreshingQuota = false; isRefreshingUpstream = false
        nextRuntimeAt = nil; nextStatusAt = nil; nextRefreshAt = nil
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
