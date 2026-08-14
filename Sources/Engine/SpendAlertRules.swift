import Foundation

/// Severity levels for spend surge / balance-drop alerts, lowest to highest.
enum SpendAlertLevel: Int, CaseIterable, Comparable, Sendable {
    case reminder = 1
    case warning = 2
    case critical = 3

    static func < (lhs: SpendAlertLevel, rhs: SpendAlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Initial, tunable thresholds. Amounts are in USD.
struct SpendAlertThresholds: Equatable, Sendable {
    var rateMultiplierL1: Double = 2
    var rateMultiplierL2: Double = 5
    var rateMultiplierL3: Double = 10
    var rateFloorL1: Double = 1
    var rateFloorL2: Double = 5
    var rateFloorL3: Double = 10
    var balanceDropL1: Double = 20
    var balanceDropL2: Double = 50
    var balanceDropL3: Double = 200

    static let standard = SpendAlertThresholds()
}

/// Pure, side-effect-free alert decision rules.
enum SpendAlertRules {
    nonisolated static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    nonisolated static func levelForSpendRate(
        current: Double,
        baseline: Double,
        thresholds: SpendAlertThresholds
    ) -> SpendAlertLevel? {
        for level in [SpendAlertLevel.critical, .warning, .reminder] {
            let (multiplier, floor) = switch level {
            case .critical: (thresholds.rateMultiplierL3, thresholds.rateFloorL3)
            case .warning:  (thresholds.rateMultiplierL2, thresholds.rateFloorL2)
            case .reminder: (thresholds.rateMultiplierL1, thresholds.rateFloorL1)
            }
            if current >= floor && current >= multiplier * baseline {
                return level
            }
        }
        return nil
    }

    nonisolated static func levelForBalanceDrop(
        dropUSD: Double,
        thresholds: SpendAlertThresholds
    ) -> SpendAlertLevel? {
        if dropUSD >= thresholds.balanceDropL3 { return .critical }
        if dropUSD >= thresholds.balanceDropL2 { return .warning }
        if dropUSD >= thresholds.balanceDropL1 { return .reminder }
        return nil
    }

    nonisolated static func shouldFire(
        lastFiredAt: Date?,
        cooldown: TimeInterval,
        now: Date
    ) -> Bool {
        guard let lastFiredAt else { return true }
        return now.timeIntervalSince(lastFiredAt) >= cooldown
    }
}
