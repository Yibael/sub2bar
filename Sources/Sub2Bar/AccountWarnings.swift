import Foundation
import Sub2BarCore

/// Presentation-only, scoped to pins and built from already-sanitized client
/// errors. Hovering an issue never performs a request or exposes response bodies.
struct AccountWarning: Identifiable, Equatable {
    let id: Int
    let name: String
    let issues: [String]
    var help: String { "\(name) · #\(id)\n" + issues.joined(separator: "\n") }

    static func collect(ids: [Int], snapshots: [AccountSnapshot], directory: [Account],
                        accountErrors: [Int: String], globalAccountError: String?,
                        dailyErrors: [Int: String], dailyStats: [Int: AccountTodayStats],
                        subscriptionIDs: Set<Int>, subscriptionErrors: [Int: String], todayActualErrors: [Int: String],
                        at date: Date) -> [AccountWarning] {
        let byID = snapshots.reduce(into: [Int: AccountSnapshot]()) { $0[$1.id] = $1 }
        let directoryByID = directory.reduce(into: [Int: Account]()) { $0[$1.id] = $1 }
        var seen = Set<Int>()
        return ids.filter { seen.insert($0).inserted }.compactMap { id in
            let snapshot = byID[id]
            let account = snapshot?.account ?? directoryByID[id]
            var issues: [String] = []
            let detailError = accountErrors[id] ?? globalAccountError
            if let detailError { issues.append("账号详情：\(detailError)") }
            if let error = dailyErrors[id] {
                if let stats = dailyStats[id] {
                    var missing: [String] = []
                    if stats.standardCost == nil { missing.append("今日用量") }
                    if account?.isAPIKeyAccount == true {
                        if stats.accountCost == nil { missing.append("账号费用") }
                        if stats.requests == nil { missing.append("请求数") }
                        if stats.tokens == nil { missing.append("Token") }
                    }
                    if !missing.isEmpty { issues.append("\(missing.joined(separator: "、"))：\(error)") }
                } else { issues.append("今日统计：\(error)") }
            }
            if account?.supportsUsageQuery == true, let error = snapshot?.usageError {
                issues.append("上游额度：\(error)")
            }
            if subscriptionIDs.contains(id) {
                if let error = subscriptionErrors[id] { issues.append("周期消费：\(error)") }
                if let error = todayActualErrors[id] { issues.append("今日实际消费：\(error)") }
            }
            // Preserve existing operational warnings in the same compact affordance.
            // Do not infer live scheduling/quota warnings from failed account details.
            if detailError == nil, let snapshot {
                let state = snapshot.account.stateLabel(at: date)
                if state != "可调度" && state != "状态未知" { issues.append("账号状态：\(state)") }
                if snapshot.usageError == nil && snapshot.needsQuotaAttention(at: date) {
                    issues.append("额度接近或已达到上限")
                }
            }
            guard !issues.isEmpty else { return nil }
            return AccountWarning(id: id, name: account?.name ?? "账号", issues: issues)
        }
    }
}

/// A partial daily response only marks the missing field; other values stay live.
enum DailyAccountField {
    case standardCost, accountCost, requests, tokens, userCost

    func failure(in stats: AccountTodayStats?, standardCost: Double?, error: String?) -> String? {
        let missing: Bool
        switch self {
        case .standardCost: missing = standardCost == nil
        case .accountCost: missing = stats?.accountCost == nil
        case .requests: missing = stats?.requests == nil
        case .tokens: missing = stats?.tokens == nil
        case .userCost: missing = stats?.userCost == nil
        }
        return missing ? error : nil
    }
}
