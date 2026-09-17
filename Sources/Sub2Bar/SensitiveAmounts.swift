import SwiftUI

private struct SensitiveAmountsHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sensitiveAmountsHidden: Bool {
        get { self[SensitiveAmountsHiddenKey.self] }
        set { self[SensitiveAmountsHiddenKey.self] = newValue }
    }
}

/// Replace the text itself so selection and accessibility cannot reveal a masked amount.
struct SensitiveAmountText: View {
    let value: String
    var prefix: String = ""
    var label: String = "金额"
    @Environment(\.sensitiveAmountsHidden) private var isHidden

    var body: some View {
        Text(prefix + (isHidden ? "••••" : value))
            .accessibilityLabel(label)
            .accessibilityValue(isHidden ? "已隐藏" : value)
    }
}

struct AmountVisibilityButton: View {
    let isHidden: Bool
    let action: () -> Void

    private var actionLabel: String { isHidden ? "显示金额" : "隐藏金额" }

    var body: some View {
        Button(action: action) {
            Image(systemName: isHidden ? "eye.slash" : "eye")
                .resizable().scaledToFit()
                .frame(width: 14, height: 14)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(NeutralButtonStyle(.ghost, compact: true))
        .foregroundStyle(.secondary)
        .help(actionLabel).accessibilityLabel(actionLabel)
        .accessibilityValue(isHidden ? "金额已隐藏" : "金额已显示")
    }
}
