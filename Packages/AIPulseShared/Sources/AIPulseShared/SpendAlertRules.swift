import Foundation

/// Severity levels for spend surge / balance-drop alerts, lowest to highest.
public enum SpendAlertLevel: Int, CaseIterable, Comparable, Sendable {
    case reminder = 1
    case warning = 2
    case critical = 3

    public static func < (lhs: SpendAlertLevel, rhs: SpendAlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Initial, tunable thresholds. Amounts are in USD.
public struct SpendAlertThresholds: Equatable, Sendable {
    public var rateMultiplierL1: Double = 2
    public var rateMultiplierL2: Double = 5
    public var rateMultiplierL3: Double = 10
    public var rateFloorL1: Double = 1
    public var rateFloorL2: Double = 5
    public var rateFloorL3: Double = 10
    public var balanceDropL1: Double = 20
    public var balanceDropL2: Double = 50
    public var balanceDropL3: Double = 200

    public static let standard = SpendAlertThresholds()

    public init(
        rateMultiplierL1: Double = 2,
        rateMultiplierL2: Double = 5,
        rateMultiplierL3: Double = 10,
        rateFloorL1: Double = 1,
        rateFloorL2: Double = 5,
        rateFloorL3: Double = 10,
        balanceDropL1: Double = 20,
        balanceDropL2: Double = 50,
        balanceDropL3: Double = 200
    ) {
        self.rateMultiplierL1 = rateMultiplierL1
        self.rateMultiplierL2 = rateMultiplierL2
        self.rateMultiplierL3 = rateMultiplierL3
        self.rateFloorL1 = rateFloorL1
        self.rateFloorL2 = rateFloorL2
        self.rateFloorL3 = rateFloorL3
        self.balanceDropL1 = balanceDropL1
        self.balanceDropL2 = balanceDropL2
        self.balanceDropL3 = balanceDropL3
    }
}

/// Pure, side-effect-free alert decision rules.
public enum SpendAlertRules {
    public nonisolated static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    public nonisolated static func levelForSpendRate(
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

    public nonisolated static func levelForBalanceDrop(
        dropUSD: Double,
        thresholds: SpendAlertThresholds
    ) -> SpendAlertLevel? {
        if dropUSD >= thresholds.balanceDropL3 { return .critical }
        if dropUSD >= thresholds.balanceDropL2 { return .warning }
        if dropUSD >= thresholds.balanceDropL1 { return .reminder }
        return nil
    }

    public nonisolated static func shouldFire(
        lastFiredAt: Date?,
        cooldown: TimeInterval,
        now: Date
    ) -> Bool {
        guard let lastFiredAt else { return true }
        return now.timeIntervalSince(lastFiredAt) >= cooldown
    }
}
