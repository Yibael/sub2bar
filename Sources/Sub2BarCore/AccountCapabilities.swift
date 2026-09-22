import Foundation

public extension Account {
    var isAPIKeyAccount: Bool { ["apikey", "api_key", "api-key", "bedrock"].contains(type ?? "") }
    var typeLabel: String {
        if isAPIKeyAccount { return type == "bedrock" ? "Bedrock" : "API Key" }
        switch type {
        case "oauth": return "OAuth"
        case "setup-token": return "Setup Token"
        default: return type ?? "类型未知"
        }
    }

    /// Mirrors the audited upstream UI's usage-query eligibility. A local quota
    /// never turns a regular API key into an OAuth usage-query account.
    var supportsUsageQuery: Bool {
        switch platform {
        case "anthropic": return ["oauth", "setup-token"].contains(type ?? "")
        case "gemini": return type == "oauth" || isAPIKeyAccount
        case "openai", "antigravity", "grok": return type == "oauth"
        default: return false
        }
    }

    var localQuotas: [AccountQuota] {
        guard isAPIKeyAccount else { return [] }
        return [
            AccountQuota(kind: .daily, limit: quotaDailyLimit, used: quotaDailyUsed,
                         resetDate: localResetDate(daily: true)),
            AccountQuota(kind: .weekly, limit: quotaWeeklyLimit, used: quotaWeeklyUsed,
                         resetDate: localResetDate(daily: false)),
            AccountQuota(kind: .total, limit: quotaLimit, used: quotaUsed)
        ].compactMap { $0 }
    }

    private func localResetDate(daily: Bool) -> Date? {
        let prefix = daily ? "quota_daily" : "quota_weekly"
        let mode = (daily ? quotaDailyResetMode : quotaWeeklyResetMode) ?? extra?.quotaString(prefix + "_reset_mode")
        let explicit = (daily ? quotaDailyResetAt : quotaWeeklyResetAt) ?? extra?.quotaString(prefix + "_reset_at")
        if mode == "fixed" { return explicit.flatMap(parseAPIDate) }
        // Only a known rolling mode (or the server's default) can use start + duration.
        guard mode == nil || mode == "rolling" else { return nil }
        guard let start = extra?.quotaString(prefix + "_start").flatMap(parseAPIDate) else { return nil }
        return start.addingTimeInterval(daily ? 24 * 3600 : 7 * 24 * 3600)
    }
}

public struct AccountQuota: Identifiable, Sendable {
    public enum Kind: String, Sendable { case daily, weekly, total }
    public let kind: Kind
    public var id: Kind { kind }
    public let limit: Double
    public let used: Double?
    public let resetDate: Date?
    public var title: String {
        switch kind { case .daily: return "日限额"; case .weekly: return "周限额"; case .total: return "总限额" }
    }
    init?(kind: Kind, limit: Double?, used: Double?, resetDate: Date? = nil) {
        guard let limit, limit.isFinite, limit > 0 else { return nil }
        self.kind = kind; self.limit = limit
        self.used = used.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.resetDate = kind == .total ? nil : resetDate
    }
    public var percentage: Double? {
        guard let used else { return nil }
        let value = used / limit * 100
        return value.isFinite ? value : nil
    }
    public func isExceeded(at date: Date) -> Bool {
        (percentage ?? 0) >= 100 && (resetDate.map { $0 > date } ?? true)
    }
}

/// Independent daily metrics. Invalid/missing fields remain unknown; no monetary
/// field substitutes for another. Only aggregate request/Token counts are retained.
public struct AccountTodayStats: Decodable, Sendable {
    public let standardCost: Double?
    public let accountCost: Double?
    public let userCost: Double?
    public let requests: Int?
    public let tokens: Int?
    private enum CodingKeys: String, CodingKey { case standardCost, cost, userCost, requests, tokens }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func amount(_ key: CodingKeys) -> Double? {
            guard let value = try? values.decode(Double.self, forKey: key), value.isFinite, value >= 0 else { return nil }
            return value
        }
        standardCost = amount(.standardCost); accountCost = amount(.cost); userCost = amount(.userCost)
        func count(_ key: CodingKeys) -> Int? {
            guard let value = try? values.decode(Int.self, forKey: key), value >= 0 else { return nil }
            return value
        }
        requests = count(.requests); tokens = count(.tokens)
    }
}
