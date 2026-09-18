import XCTest
@testable import AIPulse

final class DashboardMatrixLayoutTests: XCTestCase {
    func testSmallMatricesFillViewportIncludingCellGaps() {
        for tools in 0...2 {
            let layout = DashboardMatrixLayout(viewportWidth: 516, toolCount: tools)
            XCTAssertEqual(layout.contentWidth, 516, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(layout.modelWidth, 180)
            XCTAssertGreaterThanOrEqual(layout.numericWidth, 100)
        }
    }

    func testManyToolsOverflowRatherThanTruncateColumns() {
        let layout = DashboardMatrixLayout(viewportWidth: 516, toolCount: 8)
        XCTAssertEqual(layout.numericColumns, 9)
        XCTAssertGreaterThan(layout.contentWidth, 516)
        XCTAssertEqual(layout.numericWidth, 100)
    }

    func testUnknownAndInvalidViewportProduceFiniteMinimumWidths() {
        for width: CGFloat in [0, -100, .nan, .infinity] {
            let layout = DashboardMatrixLayout(viewportWidth: width, toolCount: 1)
            XCTAssertTrue(layout.contentWidth.isFinite)
            XCTAssertEqual(layout.modelWidth, 180)
            XCTAssertEqual(layout.numericWidth, 100)
        }
    }
}
