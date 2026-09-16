import Foundation

public struct Account: Decodable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let platform: String
    public let type: String?
    public var status: String?
    public var schedulable: Bool?
    public var concurrency: Int?
    public var currentConcurrency: Int?
    public var currentRpm: Int?
    public var activeSessions: Int?
    public let rateLimitResetAt: String?
    public let overloadUntil: String?
    public let tempUnschedulableUntil: String?
    public let extra: CodexQuotaCache?
    public let quotaWeeklyLimit: Double?
    public let quotaWeeklyUsed: Double?
    public let quotaDailyLimit: Double?
    public let quotaDailyUsed: Double?

    public var platformLabel: String {
        switch platform {
        case "openai": return "OpenAI"
        case "anthropic": return "Claude"
        case "gemini": return "Gemini"
        case "antigravity": return "Antigravity"
        default: return platform.capitalized
        }
    }
    public var isAvailable: Bool { stateLabel(at: Date()) == "可调度" }
    public var supportsPassiveUsage: Bool { platform == "anthropic" && ["oauth", "setup-token"].contains(type ?? "") }
    public func stateLabel(at now: Date) -> String {
        if status == "error" { return "错误" }
        if status == "inactive" || status == "disabled" { return "已停用" }
        if let end = rateLimitResetAt.flatMap(parseAPIDate), end > now { return "限流中" }
        if let end = overloadUntil.flatMap(parseAPIDate), end > now { return "过载中" }
        if let end = tempUnschedulableUntil.flatMap(parseAPIDate), end > now { return "暂不可调度" }
        if schedulable == false { return "已停调度" }
        return status == "active" ? "可调度" : "状态未知"
    }

    public func withRuntime(from other: Account) -> Account {
        var copy = self
        copy.concurrency = other.concurrency
        copy.currentConcurrency = other.currentConcurrency
        copy.currentRpm = other.currentRpm
        copy.activeSessions = other.activeSessions
        return copy
    }
}

/// Decode only the published, non-secret Codex snapshot fields from extra.
/// Dictionary keys intentionally bypass convertFromSnakeCase (5h / 7d keys).
public struct CodexQuotaCache: Decodable, Sendable {
    private struct Scalar: Decodable, Sendable {
        let string: String?
        let number: Double?
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            string = try? value.decode(String.self)
            number = (try? value.decode(Double.self)) ?? string.flatMap(Double.init)
        }
    }
    private let values: [String: Scalar]
    public init(from decoder: Decoder) throws {
        let all = try decoder.singleValueContainer().decode([String: Scalar].self)
        let allowed = ["codex_usage_updated_at", "codex_5h_used_percent", "codex_5h_reset_at",
                       "codex_5h_reset_after_seconds", "codex_7d_used_percent", "codex_7d_reset_at", "codex_7d_reset_after_seconds"]
        values = all.filter { allowed.contains($0.key) }
    }
    public var sampledAt: Date? { values["codex_usage_updated_at"]?.string.flatMap(parseAPIDate) }
    public func usage(at now: Date) -> UsageInfo {
        UsageInfo(fiveHour: window("5h", now: now), sevenDay: window("7d", now: now),
                  updatedAt: values["codex_usage_updated_at"]?.string, source: "server_snapshot")
    }
    private func window(_ name: String, now: Date) -> UsageWindow? {
        guard let percent = values["codex_\(name)_used_percent"]?.number, percent.isFinite, percent >= 0 else { return nil }
        var reset = values["codex_\(name)_reset_at"]?.string.flatMap(parseAPIDate)
        // Without a sample timestamp, do not slide a relative reset forward on
        // every client refresh. Unknown is more truthful than a moving deadline.
        if reset == nil, let sample = sampledAt,
           let seconds = values["codex_\(name)_reset_after_seconds"]?.number, seconds.isFinite, seconds > 0 {
            reset = sample.addingTimeInterval(seconds)
        }
        let expired = reset.map { $0 <= now } ?? false
        return UsageWindow(utilization: expired ? 0 : percent,
                           resetsAt: reset.map { ISO8601DateFormatter().string(from: $0) },
                           remainingSeconds: reset.map { max(0, Int($0.timeIntervalSince(now))) })
    }
}

public struct WindowStats: Decodable, Sendable {
    public let cost: Double?
    public let requests: Int?
    public let tokens: Int?
}

public struct UsageWindow: Decodable, Sendable {
    public let utilization: Double?
    public let resetsAt: String?
    public let remainingSeconds: Int?
    public let windowStats: WindowStats?

    public init(utilization: Double?, resetsAt: String? = nil, remainingSeconds: Int? = nil, windowStats: WindowStats? = nil) {
        self.utilization = utilization; self.resetsAt = resetsAt
        self.remainingSeconds = remainingSeconds; self.windowStats = windowStats
    }

    public var percentage: Double? {
        guard let utilization, utilization.isFinite, utilization >= 0 else { return nil }
        return utilization
    }
    public var estimatedTotalCost: Double? {
        guard let usage = percentage, usage > 0,
              let cost = windowStats?.cost, cost.isFinite, cost > 0 else { return nil }
        let estimate = cost * 100 / usage
        return estimate.isFinite ? estimate : nil
    }
    public var resetDate: Date? { resetsAt.flatMap(parseAPIDate) }
}

public struct UsageInfo: Decodable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let sevenDaySonnet: UsageWindow?
    public let geminiSharedDaily: UsageWindow?
    public let geminiProDaily: UsageWindow?
    public let geminiFlashDaily: UsageWindow?
    public let updatedAt: String?
    public let source: String?
    public let error: String?
    public let errorCode: String?
    public let isForbidden: Bool?
    public let needsReauth: Bool?

    public init(fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil, updatedAt: String? = nil, source: String? = nil) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.updatedAt = updatedAt; self.source = source
        sevenDaySonnet = nil; geminiSharedDaily = nil; geminiProDaily = nil; geminiFlashDaily = nil
        error = nil; errorCode = nil; isForbidden = nil; needsReauth = nil
    }

    public var hasError: Bool {
        !(error ?? "").isEmpty || !(errorCode ?? "").isEmpty || isForbidden == true || needsReauth == true
    }
}

public struct AccountUsageResult: Sendable {
    public let id: Int
    public let usage: UsageInfo?
    public let error: String?
    public init(id: Int, usage: UsageInfo?, error: String?) {
        self.id = id; self.usage = usage; self.error = error
    }
}

public struct AccountSnapshot: Identifiable, Sendable {
    public let account: Account
    public let usage: UsageInfo?
    public let usageError: String?
    public let statisticsUsage: UsageInfo?
    public let statisticsUpdatedAt: Date?
    public var id: Int { account.id }
    public init(account: Account, usage: UsageInfo?, usageError: String? = nil, statisticsUsage: UsageInfo? = nil, statisticsUpdatedAt: Date? = nil) {
        self.account = account
        self.usage = usage
        self.usageError = usageError
        self.statisticsUsage = statisticsUsage
        self.statisticsUpdatedAt = statisticsUpdatedAt
    }
    public var weeklyPercentage: Double? {
        if let value = usage?.sevenDay?.percentage { return value }
        guard let limit = account.quotaWeeklyLimit, limit > 0,
              let used = account.quotaWeeklyUsed, used >= 0 else { return nil }
        return used / limit * 100
    }
    public var estimatedWeeklyCost: Double? {
        // Match sub2api's OpenAI seven-day estimate; do not extrapolate other providers.
        // Cost and utilization must be from the same sampling result. Never
        // divide an old cost by a newly polled snapshot percentage.
        account.platform == "openai" ? (statisticsUsage ?? usage)?.sevenDay?.estimatedTotalCost : nil
    }
    public var weeklyCost: Double? { (statisticsUsage ?? usage)?.sevenDay?.windowStats?.cost }
}

public struct AccountPage: Decodable, Sendable {
    public let items: [Account]
    public let total: Int
    public let pages: Int?
}

public struct APIEnvelope<T: Decodable>: Decodable {
    public let code: Int
    public let data: T?
}

public func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}

public func parseAPIDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}
