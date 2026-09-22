import SwiftUI

/// Keep the indicator's slot stable during error/recovery transitions. This is
/// an informational affordance, never a disabled container for its parent view.
struct FieldFailureIndicator: View {
    let message: String?
    let label: String
    var symbol = "exclamationmark.circle"

    var body: some View {
        ZStack {
            if let message {
                Image(systemName: symbol).font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(message)
                    .accessibilityLabel("\(label)：\(message)")
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(message == nil)
    }
}
