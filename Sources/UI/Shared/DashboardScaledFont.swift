import SwiftUI

/// Dynamic Type for the robot dashboard's fixed-size typography.
///
/// `.font(.system(size:))` never scales, so users with larger text settings
/// read the dashboard at compile-time sizes. This modifier grows the point
/// size with the current text setting (relative to `.large`) but caps the
/// growth at 1.35×: the robot face is a fixed-geometry composition and cannot
/// host accessibility-maximum text, and a clipped label reads worse than a
/// capped one. Visual behavior at the default `.large` setting is unchanged.
struct DashboardScaledFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let size: CGFloat
    private let weight: Font.Weight?
    private let design: Font.Design?

    init(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) {
        self.size = size
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        let index = DynamicTypeSize.allCases.firstIndex(of: typeSize) ?? 3
        let offset = Double(max(0, index - 3)) // .large is the zero point
        let multiplier = min(1 + offset * 0.06, 1.35)
        return content.font(
            .system(size: (size * multiplier).rounded(), weight: weight, design: design)
        )
    }
}

extension View {
    /// See `DashboardScaledFont`.
    func dashboardFont(_ size: CGFloat, weight: Font.Weight? = nil,
                       design: Font.Design? = nil) -> some View {
        modifier(DashboardScaledFont(size: size, weight: weight, design: design))
    }
}
