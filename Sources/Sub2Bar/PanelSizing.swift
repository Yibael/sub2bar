import SwiftUI

enum PanelSection: Hashable { case header, footer, dashboard, accounts }

struct PanelMeasurements: PreferenceKey {
    static let defaultValue: [PanelSection: CGFloat] = [:]
    static func reduce(value: inout [PanelSection: CGFloat], nextValue: () -> [PanelSection: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum PanelSizing {
    static let width: CGFloat = 432
    static let initialHeight: CGFloat = 660
    static let placeholderHeight: CGFloat = 360
    static let accountCardHeight: CGFloat = 212
    static func hasMeasurements(_ measurements: [PanelSection: CGFloat]) -> Bool {
        [.header, .footer, .dashboard, .accounts].allSatisfy {
            (measurements[$0] ?? 0).isFinite && (measurements[$0] ?? 0) > 0
        }
    }
    static func height(measurements: [PanelSection: CGFloat], hasDashboard: Bool) -> CGFloat {
        guard hasDashboard else { return placeholderHeight }
        let sections: [PanelSection] = [.header, .footer, .dashboard, .accounts]
        guard hasMeasurements(measurements) else {
            return initialHeight
        }
        let contentHeight = sections.reduce(CGFloat.zero) { $0 + (measurements[$1] ?? 0) }
        // Only one account is mounted. Expanded details grow the window instead
        // of introducing a vertical scroll container or clipping at 660 points.
        return ceil(contentHeight + 24)
    }
}

extension View {
    func measurePanelSection(_ section: PanelSection) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: PanelMeasurements.self, value: [section: ceil(geometry.size.height)])
        })
    }
}
