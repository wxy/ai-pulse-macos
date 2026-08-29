import Foundation

/// Pure guards for values that cross the SwiftUI Charts rendering boundary.
///
/// Charts performs geometry interpolation and `Double`-to-integer conversions
/// internally. A single NaN can therefore trap in framework code long after
/// the bad value entered app state. These helpers make that boundary total:
/// every returned value is finite, and rendering values are non-negative.
nonisolated enum ChartMath {
    /// Returns `value` when finite; otherwise returns a finite fallback.
    static func finite(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, fallback.isFinite else {
            return fallback.isFinite ? fallback : 0
        }
        return value
    }

    /// Clamps animation progress to the unit interval.
    static func progress(_ value: Double) -> Double {
        guard value.isFinite else { return value > 0 ? 1 : 0 }
        return min(max(value, 0), 1)
    }

    /// Produces a safe bar height/length. Negative inputs render as zero
    /// instead of becoming inverted geometry.
    static func barValue(base: Double, progress: Double, scale: Double = 1) -> Double {
        let safeBase = finite(base, fallback: 0)
        let safeProgress = Self.progress(progress)
        let safeScale = finite(scale, fallback: 0)
        guard safeBase >= 0, safeScale >= 0 else { return 0 }
        let value = safeBase * safeProgress * safeScale
        return value.isFinite ? max(value, 0) : 0
    }

    /// Returns a finite, positive upper bound for a chart y-domain.
    static func axisMax(_ value: Double, fallback: Double) -> Double {
        let safeFallback = finite(fallback, fallback: 1)
        guard value.isFinite, value > 0 else { return safeFallback }
        return value
    }

    /// Returns a finite positive step, rejecting zero/NaN division inputs.
    static func niceStep(_ rough: Double) -> Double {
        guard let safeRough = optionalFinite(rough), safeRough > 0 else { return 1 }

        let magnitude = pow(10, floor(log10(safeRough)))
        guard let safeMagnitude = optionalFinite(magnitude), safeMagnitude > 0 else { return 1 }

        let normalized = safeRough / safeMagnitude
        guard let safeNormalized = optionalFinite(normalized) else { return 1 }

        let nice: Double
        if safeNormalized <= 1.5 { nice = 1 }
        else if safeNormalized <= 3 { nice = 2 }
        else if safeNormalized <= 7 { nice = 5 }
        else { nice = 10 }
        return finite(nice * safeMagnitude, fallback: 1)
    }

    /// Returns the next 1/2/5 decade step while guaranteeing finite input.
    static func nextNiceStep(_ step: Double) -> Double {
        let niceSteps: [Double] = [1, 2, 5, 10]
        let safeStep = finite(step, fallback: 1)
        let magnitude = pow(10, floor(log10(max(safeStep, 1))))
        guard let safeMagnitude = optionalFinite(magnitude), safeMagnitude > 0 else { return 10 }

        let mantissa = safeStep / safeMagnitude
        if let idx = niceSteps.firstIndex(where: { $0 > mantissa + 0.001 }) {
            return finite(niceSteps[idx] * safeMagnitude, fallback: 10)
        }
        return 10 * safeMagnitude
    }

    /// Divides only after proving both operands finite and denominator positive.
    static func scale(_ numerator: Double, denominator: Double, fallback: Double) -> Double {
        let safeFallback = finite(fallback, fallback: 1)
        guard numerator.isFinite, numerator >= 0 else { return safeFallback }
        let safeDenominator = finite(denominator, fallback: 0)
        guard safeDenominator > 0 else { return safeFallback }

        let result = numerator / safeDenominator
        return result.isFinite && result >= 0 ? result : safeFallback
    }

    /// Calculates a positive token-axis upper bound without raw Int overflow.
    static func tokenAxisMax(context: Int, window: Int?) -> Int {
        let contextMax = max(context, 1)
        if contextMax == 1 { return 1 }
        if let window, window > contextMax {
            return window
        }

        let padded = (Double(contextMax) * 1.15).rounded(.up)
        return Int(exactly: padded) ?? Int.max
    }

    private static func optionalFinite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }
}
