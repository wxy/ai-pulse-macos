import Foundation

/// Explicit column widths fill the viewport for a small matrix. Large matrices
/// retain readable minimums and overflow horizontally rather than losing tools.
struct DashboardMatrixLayout {
    let modelWidth: CGFloat
    let numericWidth: CGFloat
    let numericColumns: Int

    init(viewportWidth: CGFloat, toolCount: Int) {
        let viewport = viewportWidth.isFinite ? max(0, viewportWidth) : 0
        numericColumns = max(0, toolCount) + 1 // tools + total
        modelWidth = max(180, viewport * 0.38)
        numericWidth = max(100, (viewport - modelWidth - CGFloat(numericColumns)) / CGFloat(numericColumns))
    }

    var contentWidth: CGFloat {
        modelWidth + CGFloat(numericColumns) * (numericWidth + 1)
    }
}
