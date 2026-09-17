import XCTest
import GRDB
@testable import AIPulse

final class BalanceObservationTests: XCTestCase {
    private func deltas(_ samples: [(Int64, Double, String)], since: Int64 = 10,
                        before: Int64 = 100) throws -> [BalanceObservation.Delta] {
        let queue = try DatabaseQueue()
        return try queue.write { db in
            try AppDatabase.createAllTables(db)
            for sample in samples {
                try db.execute(sql: "INSERT INTO balance_snapshot (provider_id, ts, balance, currency) VALUES ('test', ?, ?, ?)",
                               arguments: [sample.0, sample.1, sample.2])
            }
            return try BalanceObservation.fetchBalanceDeltas(in: db, sinceMs: since, beforeMs: before)
        }
    }

    func testBoundaryBaselineAndSamplingIntervalAreRetained() throws {
        let result = try deltas([(9, 100, "USD"), (11, 96, "USD")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.startMs, 9)
        XCTAssertEqual(result.first?.ts, 11)
        XCTAssertEqual(result.first?.nativeAmount, 4)
    }

    func testIncreaseAndFutureSamplesAreNotSpend() throws {
        let result = try deltas([(9, 100, "USD"), (11, 95, "USD"), (12, 97, "USD"), (101, 0, "USD")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.nativeAmount, 5)
    }

    func testCumulativeUsageRemainsNativeObservedDecrease() throws {
        let result = try deltas([(9, -10, "USD"), (11, -14, "USD")])
        XCTAssertEqual(result.first?.nativeAmount, 4)
    }

    func testCurrencySwitchDoesNotSubtractDifferentDenominations() throws {
        let result = try deltas([(9, 100, "USD"), (11, 90, "CNY"), (12, 85, "CNY")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.nativeAmount, 5)
        XCTAssertEqual(result.first?.currency, "CNY")
    }

    func testUnknownCurrencyIsPreservedWithoutOneToOneUSDGuess() throws {
        let result = try deltas([(9, 100, "XXX"), (11, 96, "XXX")])
        XCTAssertEqual(result.first?.nativeAmount, 4)
        XCTAssertEqual(result.first?.currency, "XXX")
        XCTAssertNil(StatsService.semanticUSDConversion(currency: "XXX"))
    }

    func testEqualTimestampUsesLatestSampleAsBaselineNotConsumption() throws {
        let result = try deltas([(9, 100, "USD"), (11, 99, "USD"), (11, 90, "USD"), (12, 89, "USD")])
        XCTAssertEqual(result.map(\.nativeAmount), [1, 1])
    }

    func testNonFiniteSampleBreaksBaselineRatherThanCreatingSpend() throws {
        let result = try deltas([(9, 100, "USD"), (11, .infinity, "USD"), (12, 90, "USD")])
        XCTAssertTrue(result.isEmpty)
    }
}
