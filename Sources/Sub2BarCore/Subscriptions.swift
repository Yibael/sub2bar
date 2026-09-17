import Foundation

public struct AccountSubscription: Codable, Equatable, Sendable {
    public var monthlyPrice: Decimal?
    public var renewalDay: Int?

    public init(monthlyPrice: Decimal? = nil, renewalDay: Int? = nil) {
        self.monthlyPrice = monthlyPrice; self.renewalDay = renewalDay
    }

    public var isComplete: Bool {
        guard let price = monthlyPrice, !price.isNaN, price >= 0,
              let day = renewalDay, (1...31).contains(day) else { return false }
        return true
    }

    public static func parseMonthlyPrice(_ text: String) throws -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.range(of: #"^\d{1,9}(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let price = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !price.isNaN else {
            throw SubscriptionError.invalidConfiguration
        }
        return price
    }
}

/// Local metadata only. Unpinning does not delete a subscription configuration.
public struct SubscriptionPreferences: Codable, Sendable {
    private var servers: [String: [Int: AccountSubscription]] = [:]
    public init() {}
    public func subscriptions(for server: String) -> [Int: AccountSubscription] { servers[server] ?? [:] }
    public mutating func set(_ subscription: AccountSubscription?, id: Int, server: String) {
        guard id > 0 else { return }
        servers[server, default: [:]][id] = subscription
    }
}

public struct SubscriptionCycle: Equatable, Sendable {
    public let start: Date
    public let end: Date // Exclusive; the next renewal day at local midnight.
    public let timeZoneID: String

    /// Calendar-month recurrence, clamping short months without shifting the
    /// original renewal day. This is a local reporting rule, not a billing API.
    public init?(renewalDay: Int, at date: Date, timeZoneID: String) {
        guard (1...31).contains(renewalDay), let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let month = calendar.dateInterval(of: .month, for: date)?.start else { return nil }
        func boundary(_ month: Date) -> Date? {
            guard let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
            return calendar.date(byAdding: .day, value: min(renewalDay, days.count) - 1, to: month)
        }
        guard let current = boundary(month),
              let startMonth = calendar.date(byAdding: .month, value: date < current ? -1 : 0, to: month),
              let endMonth = calendar.date(byAdding: .month, value: 1, to: startMonth),
              let start = boundary(startMonth), let end = boundary(endMonth) else { return nil }
        self.start = start; self.end = end; self.timeZoneID = timeZoneID
    }

    public func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZoneID)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    /// The last included instant lies on the day before the next renewal.
    /// Subtract one second, not 24 hours: calendar days can cross DST changes.
    public var lastIncludedDate: Date { end.addingTimeInterval(-1) }
    public var label: String { "\(dateString(start)) → \(dateString(lastIncludedDate))" }
    public var shortLabel: String {
        let first = dateString(start).suffix(5).replacingOccurrences(of: "-", with: "/")
        let last = dateString(lastIncludedDate).suffix(5).replacingOccurrences(of: "-", with: "/")
        return "\(first)–\(last)"
    }
}

public struct SubscriptionUsageRequest: Equatable, Sendable {
    public let accountID: Int
    public let cycle: SubscriptionCycle
    public init(accountID: Int, cycle: SubscriptionCycle) { self.accountID = accountID; self.cycle = cycle }
}

public struct SubscriptionUsageResult: Sendable {
    public let request: SubscriptionUsageRequest
    public let actualCost: Decimal?
    public let error: String?
    public let todayActualCost: Decimal?
    public let todayError: String?
    public init(request: SubscriptionUsageRequest, actualCost: Decimal?, error: String?,
                todayActualCost: Decimal? = nil, todayError: String? = nil) {
        self.request = request; self.actualCost = actualCost; self.error = error
        self.todayActualCost = todayActualCost; self.todayError = todayError
    }
}

public struct TodayActualUsageSample: Sendable {
    public let day: String
    public let timeZoneID: String
    public let actualCost: Decimal
    public let includesAdmin: Bool
    public let sampledAt: Date
    public init(day: String, timeZoneID: String, actualCost: Decimal, includesAdmin: Bool, sampledAt: Date) {
        self.day = day; self.timeZoneID = timeZoneID; self.actualCost = actualCost
        self.includesAdmin = includesAdmin; self.sampledAt = sampledAt
    }
}

public struct SubscriptionUsageSample: Sendable {
    public let cycle: SubscriptionCycle
    public let actualCost: Decimal
    public let includesAdmin: Bool
    public let sampledAt: Date
    public init(cycle: SubscriptionCycle, actualCost: Decimal, includesAdmin: Bool, sampledAt: Date) {
        self.cycle = cycle; self.actualCost = actualCost
        self.includesAdmin = includesAdmin; self.sampledAt = sampledAt
    }
}

public enum SubscriptionError: Error, LocalizedError {
    case invalidConfiguration, unsupportedAccount, invalidStatistics, invalidAdminList, invalidCurrencyUnit
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请填写有效的订阅价格、每月 1–31 日及统计时区。"
        case .unsupportedAccount: return "仅 OAuth 账号支持本地订阅配置。"
        case .invalidStatistics: return "实际扣费统计缺失或口径不一致，请稍后重试。"
        case .invalidAdminList: return "无法完整识别 Admin 用户，未生成排除 Admin 的统计。"
        case .invalidCurrencyUnit: return "货币符号请填写 1–12 个字符，例如 ¥、$、€，不可包含换行或控制字符。"
        }
    }
}

/// Presentation only: neither currency selection nor formatting converts values.
public enum CurrencyUnit {
    public static func normalized(_ text: String) throws -> String {
        let unit = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty, unit.count <= 12,
              unit.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw SubscriptionError.invalidCurrencyUnit
        }
        return unit
    }

    /// Only for settings written before literal-symbol support. New input is
    /// never interpreted as a currency code or modified into a regional symbol.
    public static func migrateLegacy(_ text: String) -> String {
        let symbols = ["USD": "$", "CNY": "¥", "RMB": "¥", "CN¥": "¥", "JPY": "¥",
                       "EUR": "€", "GBP": "£", "HKD": "HK$", "CAD": "CA$", "AUD": "A$",
                       "KRW": "₩", "INR": "₹", "RUB": "₽"]
        let unit = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return symbols[unit.uppercased()] ?? unit
    }

    public static func format(_ value: Decimal?, unit: String = "$") -> String {
        guard let value, !value.isNaN, let unit = try? normalized(unit) else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        // Format the number only, then prepend exactly the configured symbol.
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let amount = formatter.string(from: NSDecimalNumber(decimal: value)) else { return "—" }
        return "\(unit)\(amount)"
    }
}
