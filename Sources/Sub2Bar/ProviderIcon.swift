import SwiftUI

enum ProviderBrand: String, CaseIterable {
    case openai, anthropic, gemini, antigravity

    init?(platform: String) {
        self.init(rawValue: platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var path: Path {
        switch self {
        case .openai: return LobeBrandPaths.openai
        case .anthropic: return LobeBrandPaths.claude
        case .gemini: return LobeBrandPaths.gemini
        case .antigravity: return LobeBrandPaths.antigravity
        }
    }
}

struct ProviderBrandShape: Shape {
    let brand: ProviderBrand

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return brand.path.applying(CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - 12 * scale, ty: rect.midY - 12 * scale))
    }
}

/// Bundled vector artwork; never load icons from a server or CDN at runtime.
struct ProviderIcon: View {
    let platform: String

    var body: some View {
        Group {
            if let brand = ProviderBrand(platform: platform) {
                ProviderBrandShape(brand: brand).fill(style: FillStyle(eoFill: true))
            } else {
                Text(platform.isEmpty ? "?" : String(platform.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(width: 18, height: 18)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}
