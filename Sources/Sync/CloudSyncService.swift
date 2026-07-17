import CloudKit
import Foundation

/// Syncs the cached dashboard snapshots from GRDB to iCloud.
/// iOS/watchOS read per-range snapshots to display correct data per tab.
@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase

    private init() {}

    func syncFromCache() async {
        for (key, recordName) in [("today", "snapshot-today"), ("week", "snapshot-week"), ("30d", "snapshot-30d")] {
            guard let snap = await DashboardCache.read(timeRange: key, maxAge: 600),
                  let data = try? JSONEncoder().encode(snap),
                  let json = String(data: data, encoding: .utf8) else { continue }

            let record = CKRecord(recordType: "DashboardCache_v1", recordID: CKRecord.ID(recordName: recordName))
            record["json"] = json
            record["updatedAt"] = snap.updatedAt

            do {
                let (_, results) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
                let ok = results.compactMap({ _, r in if case .failure = r { return true }; return nil }).isEmpty
                if ok { Logger.debug("CloudSync: synced \(key) len=\(json.count)") }
            } catch {
                Logger.warning("CloudSync: \(key) save failed")
            }
        }
    }
}
