import CloudKit
import Foundation

private nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f
}()

/// Writes a single summary record to iCloud after each DataRefreshCoordinator cycle.
/// Mobile apps (iOS/watchOS) read this one record — no raw data needed.
@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase

    private init() {}

    /// Sync all dashboard data as a single summary record.
    /// Mobile apps read this one record to display the full dashboard.
    func syncDashboard(
        todayCost: Double,
        weekCost: Double,
        monthCost: Double,
        providerBreakdown: [(providerId: String, name: String, cost: Double)],
        topRepos: [(name: String, cost: Double)],
        weekTrend: [(date: Date, cost: Double)]
    ) async {
        let recordID = CKRecord.ID(recordName: "dashboard-summary")
        let r = CKRecord(recordType: "DashboardSummary", recordID: recordID)

        // Totals
        r["todayCost"] = todayCost
        r["weekCost"] = weekCost
        r["monthCost"] = monthCost
        r["updatedAt"] = Date()

        // Provider breakdown → JSON string
        let providers: [[String: Any]] = providerBreakdown.map {
            ["id": $0.providerId, "name": $0.name, "cost": $0.cost]
        }
        if let pd = try? JSONSerialization.data(withJSONObject: providers) {
            r["providerBreakdown"] = String(data: pd, encoding: .utf8)
        }

        // Top repos → JSON string
        let repos: [[String: Any]] = topRepos.map {
            ["name": $0.name, "cost": $0.cost]
        }
        if let rd = try? JSONSerialization.data(withJSONObject: repos) {
            r["topRepos"] = String(data: rd, encoding: .utf8)
        }

        // Weekly trend (7 days) → JSON string
        let trend: [[String: Any]] = weekTrend.map {
            ["date": isoFormatter.string(from: $0.date), "cost": $0.cost]
        }
        if let td = try? JSONSerialization.data(withJSONObject: trend) {
            r["weekTrend"] = String(data: td, encoding: .utf8)
        }

        do {
            let (_, results) = try await database.modifyRecords(saving: [r], deleting: [], savePolicy: .allKeys)
            let failed = results.compactMap { _, result in
                if case .failure = result { return true }; return nil
            }
            if failed.isEmpty {
                // Verify the record is actually readable
                do {
                    let check = try await database.record(for: recordID)
                    Logger.debug("CloudSync: saved + read-back OK — todayCost=\(check["todayCost"] ?? 0)")
                } catch {
                    Logger.error("CloudSync: save claimed success but read-back failed: \(error.localizedDescription)")
                }
            } else {
                Logger.warning("CloudSync: summary save had \(failed.count) failures")
            }
        } catch {
            Logger.warning("CloudSync: save failed — \(error.localizedDescription)")
        }
    }
}
