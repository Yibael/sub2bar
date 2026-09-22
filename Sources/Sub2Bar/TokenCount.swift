import Foundation

func compactTokenCount(_ count: Int?) -> String {
    guard let count, count >= 0 else { return "—" }
    let units: [(Int, String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
    for (divisor, suffix) in units where count >= divisor {
        return (Double(count) / Double(divisor)).formatted(.number.locale(Locale(identifier: "en_US"))
            .precision(.fractionLength(0...2))) + suffix
    }
    return String(count)
}
