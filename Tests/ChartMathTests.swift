import XCTest
@testable import AIPulse
import AIPulseShared

final class ChartMathTests: XCTestCase {
    func testCompactCountUsesKThroughTWithOneDecimal() {
        XCTAssertEqual(ChartMath.compactCount(999), "999")
        XCTAssertEqual(ChartMath.compactCount(1_000), "1.0K")
        XCTAssertEqual(ChartMath.compactCount(1_250_000), "1.2M")
        XCTAssertEqual(ChartMath.compactCount(2_700_000_000), "2.7G")
        XCTAssertEqual(ChartMath.compactCount(3_000_000_000_000), "3.0T")
        XCTAssertEqual(ChartMath.compactCount(-12_500), "-12.5K")
    }
    @MainActor
    func testChartXDomainProvidesExplicitSpanForSingleDate() {
        let start = Calendar.current.startOfDay(for: Date())

        let domain = DashboardView.chartXDomain(start: start, days: 1)

        XCTAssertEqual(domain.lowerBound, start)
        XCTAssertEqual(
            Calendar.current.dateComponents([.day], from: start, to: domain.upperBound).day,
            1
        )
    }

    func testFiniteUsesFallbackForNonFiniteValues() {
        XCTAssertEqual(ChartMath.finite(.nan, fallback: 7), 7)
        XCTAssertEqual(ChartMath.finite(.infinity, fallback: 7), 7)
        XCTAssertEqual(ChartMath.finite(-.infinity, fallback: 7), 7)
        XCTAssertEqual(ChartMath.finite(3.25, fallback: 7), 3.25)
    }

    func testProgressIsClampedToUnitInterval() {
        XCTAssertEqual(ChartMath.progress(.nan), 0)
        XCTAssertEqual(ChartMath.progress(-0.4), 0)
        XCTAssertEqual(ChartMath.progress(-.infinity), 0)
        XCTAssertEqual(ChartMath.progress(0.35), 0.35, accuracy: 0.000001)
        XCTAssertEqual(ChartMath.progress(1.4), 1)
        XCTAssertEqual(ChartMath.progress(.infinity), 1)
    }

    func testBarValueRejectsNonFiniteAndNegativeGeometry() {
        XCTAssertEqual(ChartMath.barValue(base: .nan, progress: 1), 0)
        XCTAssertEqual(ChartMath.barValue(base: 12, progress: .nan), 0)
        XCTAssertEqual(ChartMath.barValue(base: 12, progress: 1, scale: .nan), 0)
        XCTAssertEqual(ChartMath.barValue(base: -4, progress: 1), 0)
        XCTAssertEqual(ChartMath.barValue(base: -4, progress: 1, scale: -2), 0)
        XCTAssertEqual(
            ChartMath.barValue(base: 8, progress: 0.5, scale: 2),
            8,
            accuracy: 0.000001
        )
    }

    func testAxisMaxAlwaysReturnsPositiveFiniteValue() {
        XCTAssertEqual(ChartMath.axisMax(.nan, fallback: 10), 10)
        XCTAssertEqual(ChartMath.axisMax(.infinity, fallback: 10), 10)
        XCTAssertEqual(ChartMath.axisMax(-1, fallback: 10), 10)
        XCTAssertEqual(ChartMath.axisMax(0, fallback: 10), 10)
        XCTAssertEqual(ChartMath.axisMax(3.25, fallback: 10), 3.25)
    }

    func testNiceStepRejectsNonFiniteDivisionInputs() {
        XCTAssertEqual(ChartMath.niceStep(.nan), 1)
        XCTAssertEqual(ChartMath.niceStep(0), 1)
        XCTAssertEqual(ChartMath.niceStep(2), 2)
        XCTAssertEqual(ChartMath.niceStep(4), 5)
    }

    func testScaleRejectsInvalidDenominatorAndValues() {
        XCTAssertEqual(ChartMath.scale(12, denominator: 0, fallback: 1), 1)
        XCTAssertEqual(ChartMath.scale(12, denominator: .nan, fallback: 1), 1)
        XCTAssertEqual(ChartMath.scale(.nan, denominator: 4, fallback: 1), 1)
        XCTAssertEqual(ChartMath.scale(12, denominator: 4, fallback: 1), 3)
    }

    func testRatioReturnsFiniteFractionOrFallback() {
        XCTAssertEqual(ChartMath.ratio(5, denominator: 10, fallback: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ChartMath.ratio(.nan, denominator: 10, fallback: 1), 0)
        XCTAssertEqual(ChartMath.ratio(-3, denominator: 10, fallback: 1), 0)
        XCTAssertEqual(ChartMath.ratio(5, denominator: 0, fallback: 1), 1)
        XCTAssertEqual(ChartMath.ratio(5, denominator: .infinity, fallback: 1), 1)
        // Overflowing division must fall back instead of producing +Inf.
        XCTAssertEqual(ChartMath.ratio(1e308, denominator: 1e-308, fallback: 1), 1)
    }

    func testPercentageDeltaRejectsNonFiniteInputs() {
        XCTAssertEqual(ChartMath.percentageDelta(current: 110, previous: 100, fallback: 0), 10, accuracy: 0.0001)
        XCTAssertEqual(ChartMath.percentageDelta(current: .nan, previous: 100, fallback: 0), 0)
        XCTAssertEqual(ChartMath.percentageDelta(current: 110, previous: .infinity, fallback: 0), 0)
        XCTAssertEqual(ChartMath.percentageDelta(current: 110, previous: 0, fallback: 0), 0)
    }

    func testUnitClampsToUnitInterval() {
        XCTAssertEqual(ChartMath.unit(.nan), 0)
        XCTAssertEqual(ChartMath.unit(-0.3), 0)
        XCTAssertEqual(ChartMath.unit(0.35), 0.35, accuracy: 0.000001)
        XCTAssertEqual(ChartMath.unit(1.7), 1)
        XCTAssertEqual(ChartMath.unit(.infinity), 0)
    }

    func testSafeIntClampsInsteadOfTrapping() {
        XCTAssertEqual(ChartMath.safeInt(.nan), 0)
        XCTAssertEqual(ChartMath.safeInt(.infinity), 0)
        XCTAssertEqual(ChartMath.safeInt(-.infinity), 0)
        XCTAssertEqual(ChartMath.safeInt(3.7), 3)
        XCTAssertEqual(ChartMath.safeInt(1e30), Int.max)
        XCTAssertEqual(ChartMath.safeInt(-1e30), Int.min)
    }

    func testTokenAxisMaxFallsBackToAtLeastOne() {
        XCTAssertEqual(ChartMath.tokenAxisMax(context: 0, window: nil), 1)
        XCTAssertEqual(ChartMath.tokenAxisMax(context: -10, window: nil), 1)
        XCTAssertEqual(ChartMath.tokenAxisMax(context: .max, window: nil), Int.max)
        XCTAssertEqual(ChartMath.tokenAxisMax(context: 100, window: nil), 115)
        XCTAssertEqual(ChartMath.tokenAxisMax(context: 100, window: 200), 200)
    }

    @MainActor
    func testRenderableDonutSegmentsExcludesZeroAndInvalidTokens() {
        let segments = [
            DashboardView.DonutItem(label: "error", tokens: 0, pct: 0, color: .gray),
            DashboardView.DonutItem(label: "invalid", tokens: .nan, pct: 0, color: .gray),
            DashboardView.DonutItem(label: "negative", tokens: -1, pct: 0, color: .gray),
            DashboardView.DonutItem(label: "valid", tokens: 2, pct: 100, color: .gray),
        ]

        let result = DashboardView.renderableDonutSegments(segments)

        XCTAssertEqual(result.map(\.label), ["valid"])
    }

    @MainActor
    func testTokenDonutGroupingPreservesObservedTotalAndRepositoryIdentity() {
        let items = (1...5).map { index in
            DashboardView.DonutItem(label: "same name", tokens: Double(index), pct: 0,
                                    color: .gray, id: "/development/repo-\(index)")
        }
        let grouped = DashboardView.topSegments(items)
        XCTAssertEqual(grouped.count, 4)
        XCTAssertEqual(grouped.reduce(0) { $0 + $1.tokens }, 15)
        XCTAssertEqual(grouped.prefix(3).map(\.id),
                       ["/development/repo-5", "/development/repo-4", "/development/repo-3"])
        XCTAssertEqual(grouped.last?.tokens, 3)
    }
}
