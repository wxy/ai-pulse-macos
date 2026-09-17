import CloudKit
import Foundation
import AIPulseShared

/// Syncs the cached dashboard snapshots from GRDB to iCloud.
/// iOS/watchOS read per-range snapshots to display correct data per tab.
@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    /// Do not construct CKContainer until a release build actually needs a
    /// CloudKit operation. Debug builds disable writes and must not crash while
    /// initializing an unavailable/misconfigured container.
    private var database: CKDatabase {
        CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase
    }

    private static let allowsCloudWrites: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    /// Content fingerprint (updatedAt excluded) of the last snapshot actually
    /// written per range. Used to skip no-op CloudKit writes — see
    /// `syncFromCache()`.
    private var lastSyncedFingerprint: [String: Int] = [:]

    private init() {}

    func syncFromCache() async {
        guard Self.allowsCloudWrites else {
            Logger.info("CloudSync: dashboard writes disabled in Debug")
            return
        }

        Logger.info("CloudSync: starting sync")
        let ranges: [(key: String, recordName: String, maxAge: TimeInterval)] = [
            ("today", CKSchema.RecordName.today, 600),
            ("week", CKSchema.RecordName.week, 3600),
            ("30d", CKSchema.RecordName.month, 43200),
        ]
        for r in ranges {
            let snap: DashboardSnapshot
            // Try cache first; if missing/stale, compute directly
            if let cached = await DashboardCache.read(timeRange: r.key, maxAge: r.maxAge) {
                snap = cached
            } else {
                guard let period = DashboardPeriodKind(rawValue: r.key) else { continue }
                snap = await StatsService.dashboardSnapshot(period: period)
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
        await syncCurrentPulse()
    }

    private func syncCurrentPulse() async {
        let now = Date()
        let envelope = CurrentPulseEnvelope(pulse: await PulseEngine.shared.snapshot(),
                                            writerAppVersion: CKSchema.writerAppVersion, generatedAt: now)
        guard let data = try? JSONEncoder().encode(envelope),
              let json = String(data: data, encoding: .utf8) else { return }
        let record = CKRecord(recordType: CKSchema.CurrentPulse.recordType,
                              recordID: CKRecord.ID(recordName: CKSchema.CurrentPulse.recordName))
        record[CKSchema.Field.json] = json
        record[CKSchema.Field.updatedAt] = now
        do {
            let (_, results) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            for (_, result) in results {
                if case .failure(let error) = result { Logger.error("CloudSync current pulse record failed: \(error)") }
            }
        } catch {
            Logger.error("CloudSync current pulse failed: \(error)")
        }
    }

    /// Upsert the latest spend-surge / balance-drop alert for iOS readers.
    func writeSpendAlert(_ payload: SpendAlertPayload) async {
        guard Self.allowsCloudWrites else {
            Logger.info("CloudSync: spend-alert CloudKit write disabled in Debug")
            return
        }

        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            Logger.error("CloudSync: spend alert encode failed")
            return
        }

        let record = CKRecord(
            recordType: CKSchema.SpendAlert.recordType,
            recordID: CKRecord.ID(recordName: CKSchema.SpendAlert.recordName)
        )
        record[CKSchema.SpendAlert.Field.json] = json
        record[CKSchema.SpendAlert.Field.updatedAt] = payload.occurredAt

        do {
            let (_, results) = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys)
            let failed = results.contains { _, result in
                if case .failure = result { return true }
                return false
            }
            if failed {
                Logger.error("CloudSync: spend alert save failed")
            } else {
                Logger.info("CloudSync: wrote spend alert \(payload.kind) L\(payload.level)")
            }
        } catch {
            Logger.error("CloudSync: spend alert save failed: \(error)")
        }
    }
}
