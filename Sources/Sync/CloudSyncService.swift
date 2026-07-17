import CloudKit
import Foundation

/// Syncs the cached dashboard snapshot from GRDB to iCloud.
/// iOS/watchOS read the same snapshot to display their dashboards.
@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase

    private init() {}

    /// Read the latest snapshot from the local cache and sync to iCloud.
    func syncFromCache() async {
        guard let snapshot = await DashboardCache.read(timeRange: "today", maxAge: 600),
              let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }

        let recordID = CKRecord.ID(recordName: "dashboard-snapshot")
        let record = CKRecord(recordType: "DashboardSnapshot_v1", recordID: recordID)
        record["version"] = 1
        record["json"] = json
        record["updatedAt"] = snapshot.updatedAt

        do {
            let (_, results) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            if results.compactMap({ _, r in if case .failure = r { return true }; return nil }).isEmpty {
                Logger.debug("CloudSync: snapshot synced")
            }
        } catch {
            Logger.warning("CloudSync: save failed — \(error.localizedDescription)")
        }
    }
}
