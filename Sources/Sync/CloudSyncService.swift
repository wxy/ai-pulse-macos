import CloudKit
import Foundation

/// Syncs the cached dashboard snapshots from GRDB to iCloud.
/// iOS/watchOS read per-range snapshots to display correct data per tab.
@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase

    /// Content fingerprint (updatedAt excluded) of the last snapshot actually
    /// written per range. Used to skip no-op CloudKit writes — see
    /// `syncFromCache()`.
    private var lastSyncedFingerprint: [String: Int] = [:]

    private init() {}

    func syncFromCache() async {
        Logger.info("CloudSync: starting sync")
        // Per-range config: days, cache maxAge
        let ranges: [(key: String, recordName: String, days: Int, maxAge: TimeInterval)] = [
            ("today", CKSchema.RecordName.today, 1, 600),
            ("week", CKSchema.RecordName.week, 7, 3600),
            ("30d", CKSchema.RecordName.month, 30, 43200),
        ]
        for r in ranges {
            let snap: DashboardSnapshot
            // Try cache first; if missing/stale, compute directly
            if let cached = await DashboardCache.read(timeRange: r.key, maxAge: r.maxAge) {
                snap = cached
            } else {
                snap = await StatsService.dashboardSnapshot(days: r.days)
            }
            guard let data = try? JSONEncoder().encode(snap),
                  let json = String(data: data, encoding: .utf8) else { continue }

            // This runs every ~5 min (throttled by DataRefreshCoordinator),
            // but the underlying numbers often haven't changed between
            // cycles. Every CloudKit write fires the iOS/watchOS
            // CKQuerySubscription silent push, which wakes those devices in
            // the background to fetch — on devices with flaky Wi-Fi
            // hardware (e.g. iPhone SE 2nd gen), that's extra radio activity
            // several times an hour even when nobody is using the app.
            // Skip the write (and the push) entirely when only `updatedAt`
            // would differ.
            var contentSnap = snap
            contentSnap.updatedAt = Date(timeIntervalSince1970: 0)
            let fingerprint = (try? JSONEncoder().encode(contentSnap))?.hashValue
            if let fingerprint, lastSyncedFingerprint[r.key] == fingerprint {
                Logger.debug("CloudSync: \(r.key) unchanged, skipping push")
                continue
            }

            let record = CKRecord(recordType: CKSchema.recordType, recordID: CKRecord.ID(recordName: r.recordName))
            record[CKSchema.Field.json] = json
            record[CKSchema.Field.updatedAt] = snap.updatedAt

            do {
                let (_, results) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
                let ok = results.compactMap({ _, r in if case .failure = r { return true }; return nil }).isEmpty
                if ok {
                    Logger.info("CloudSync: synced \(r.key) len=\(json.count)")
                    lastSyncedFingerprint[r.key] = fingerprint
                }
            } catch {
                Logger.error("CloudSync: \(r.key) save failed: \(error)")
            }
        }
    }
}
