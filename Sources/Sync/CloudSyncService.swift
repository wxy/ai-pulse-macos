import CloudKit
import Foundation

/// Writes aggregated spending data from macOS to iCloud Private DB.
/// Called after each DataRefreshCoordinator cycle so iOS/watchOS can display
/// the same data without having their own data collection.
@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    private let container = CKContainer(identifier: "iCloud.com.wxy.aipulse")
    private let database: CKDatabase

    private init() {
        // Use public CloudKit database for dev/test (schema already deployed to Production)
        database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase
    }

    // MARK: - Public API

    /// Sync pre-computed totals so iOS/watchOS show the same numbers as macOS.
    func syncTotals(today: Double, week: Double, month: Double) async {
        let recordID = CKRecord.ID(recordName: "app-config")
        let r = CKRecord(recordType: "AppConfig", recordID: recordID)
        r["todayCost"] = today
        r["weekCost"] = week
        r["monthCost"] = month
        r["updatedAt"] = Date()
        await save([r])
    }

    /// Sync the latest aggregated stats to iCloud.
    /// Called by DataRefreshCoordinator after each refresh cycle.
    func syncDailyStats(_ stats: [DailyStat]) async {
        await save(stats.map { stat in
            let r = CKRecord(recordType: "DailyStat")
            r["date"] = stat.date
            r["cost"] = stat.cost
            r["calls"] = stat.calls
            r["tokens"] = stat.tokens
            r["netLines"] = stat.netLines
            r["costPerLine"] = stat.costPerLine
            return r
        })
    }

    func syncCodeChanges(_ changes: [DailyCodeChange]) async {
        await save(changes.map { change in
            let r = CKRecord(recordType: "DailyCodeChange")
            r["date"] = change.date
            r["added"] = change.added
            r["deleted"] = change.deleted
            return r
        })
    }

    func syncProviderCosts(_ costs: [ProviderDailyCost]) async {
        await save(costs.map { cost in
            let r = CKRecord(recordType: "ProviderCost")
            r["date"] = cost.date
            r["providerId"] = cost.providerId
            r["cost"] = cost.cost
            return r
        })
    }

    // MARK: - Private

    private func save(_ records: [CKRecord]) async {
        guard !records.isEmpty else { return }
        do {
            let (_, results) = try await database.modifyRecords(
                saving: records, deleting: [], savePolicy: .allKeys
            )
            let failed = results.compactMap { _, result in
                if case .failure = result { return true }; return nil
            }
            if failed.isEmpty {
                Logger.debug("CloudSync: saved \(records.count) records")
            } else {
                Logger.warning("CloudSync: \(failed.count)/\(records.count) records failed")
            }
        } catch {
            Logger.warning("CloudSync: save failed — \(error.localizedDescription)")
        }
    }

    private func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }
}
