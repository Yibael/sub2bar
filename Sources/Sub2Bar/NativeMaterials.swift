import AppKit
import SwiftUI

private struct MenuPanelSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isMenuPanelSurface: Bool {
        get { self[MenuPanelSurfaceKey.self] }
        set { self[MenuPanelSurfaceKey.self] = newValue }
    }
}

enum SurfaceStyle {
    static func fill(panel: Bool, reduceTransparency: Bool, dark: Bool) -> Color {
        if reduceTransparency { return Color(nsColor: .controlBackgroundColor) }
        if panel { return .clear }
        return Color.white.opacity(dark ? 0.025 : 0.18)
    }
}

/// A subtle content grouping, not another sheet of glass. NSPopover owns the
/// outer native material (Liquid Glass on macOS 26; vibrancy on earlier macOS).
struct InsetSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isMenuPanelSurface) private var isMenuPanelSurface

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.3 : 0.1), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }

    private var fill: Color {
        SurfaceStyle.fill(panel: isMenuPanelSurface, reduceTransparency: reduceTransparency, dark: colorScheme == .dark)
    }
}

/// shadcn-inspired monochrome controls, drawn natively with SwiftUI. Color is
/// semantic so the primary action inverts in dark mode. Focus remains native.
struct NeutralButtonStyle: ButtonStyle {
    enum Variant { case primary, outline, ghost }
    var variant: Variant
    var compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ variant: Variant = .outline, compact: Bool = false) {
        self.variant = variant
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, compact ? 6 : 12)
            .padding(.vertical, compact ? 6 : 8)
            .foregroundStyle(variant == .primary ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(variant == .outline ? (contrast == .increased ? 0.4 : 0.16) : 0), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.35)
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary: return Color.primary.opacity(pressed ? 0.75 : 1)
        case .outline: return Color.primary.opacity(pressed ? 0.09 : 0.025)
        case .ghost: return Color.primary.opacity(pressed ? 0.09 : 0)
        }
    }
}

extension View {
    func insetSurface(cornerRadius: CGFloat) -> some View {
        modifier(InsetSurface(cornerRadius: cornerRadius))
    }
}
