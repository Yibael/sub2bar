import Foundation

public enum ResetCountdown {
    /// Use the server's absolute deadline, never restart a relative duration
    /// when the panel opens or a view is recomputed.
    public static func text(until deadline: Date?, at now: Date) -> String {
        guard let deadline else { return "—" }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining.isFinite, remaining < Double(Int.max) else { return "—" }
        guard remaining > 0 else { return "等待更新" }
        let seconds = Int(remaining)
        if seconds >= 86_400 { return "\(seconds / 86_400)d \(seconds % 86_400 / 3_600)h" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "<1m"
    }
}
