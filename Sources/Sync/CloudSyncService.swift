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

        let recordID = CKRecord.ID(recordName: "snapshot")
        let record = CKRecord(recordType: "DashboardCache_v1", recordID: recordID)
        record["json"] = json
        record["updatedAt"] = snapshot.updatedAt

        do {
            let (_, results) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            let failures = results.compactMap { _, r in if case .failure(let e) = r { return e }; return nil }
            if failures.isEmpty {
                // Verify read-back
                if let check = try? await database.record(for: recordID) {
                    let js = (check["json"] as? String) ?? ""
                    let hasCC = js.contains("codeChanges")
                    let hasTR = js.contains("topRepos")
                    Logger.debug("CloudSync: synced OK, len=\(js.count), codeChanges=\(hasCC), topRepos=\(hasTR)")
                } else {
                    Logger.warning("CloudSync: synced but read-back failed")
                }
            } else {
                Logger.warning("CloudSync: \(failures.count) failures — \(failures.first!.localizedDescription)")
            }
        } catch {
            Logger.warning("CloudSync: save failed — \(error.localizedDescription)")
        }
    }
}
