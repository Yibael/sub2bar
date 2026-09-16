import Foundation

/// Counts only pinned accounts, separating missing or failed data from known states.
public struct PinnedAccountOverview {
    public let total: Int
    public private(set) var available = 0
    public private(set) var failed = 0
    public private(set) var pending = 0
    public private(set) var unknown = 0
    public private(set) var attention = 0

    public init(ids: [Int], snapshots: [AccountSnapshot], failedIDs: Set<Int>, stale: Bool = false, at date: Date = Date()) {
        let pins = Set(ids)
        total = pins.count
        let byID = snapshots.reduce(into: [Int: AccountSnapshot]()) { $0[$1.id] = $1 }
        for id in pins {
            if stale || failedIDs.contains(id) { failed += 1; continue }
            guard let snapshot = byID[id] else { pending += 1; continue }
            let state = snapshot.account.stateLabel(at: date)
            if state == "状态未知" { unknown += 1 }
            else if state == "可调度" { available += 1 }
            if (state != "可调度" && state != "状态未知") ||
                (snapshot.weeklyPercentage ?? 0) >= 90 ||
                (snapshot.usage?.fiveHour?.percentage ?? 0) >= 90 || snapshot.usageError != nil {
                attention += 1
            }
        }
    }

    public var statusText: String {
        var parts: [String] = []
        if failed == 0 && pending == 0 && unknown == 0 && available < total {
            parts.append("可调度 \(available)/\(total)")
        }
        if failed > 0 { parts.append("读取失败 \(failed)") }
        if pending > 0 { parts.append("待载入 \(pending)") }
        if unknown > 0 { parts.append("状态未知 \(unknown)") }
        return parts.joined(separator: " · ")
    }
}
