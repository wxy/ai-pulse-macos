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
    static let didChange = Notification.Name("cloudSyncStatusDidChange")
    enum Result: Equatable { case idle, disabled, syncing, succeeded, failed }
    private(set) var result: Result = .idle
    private(set) var accountText = SetupCopy.text("尚未检查 iCloud 账户", "iCloud account not checked")
    var lastSuccess: Date? {
        let seconds = UserDefaults.standard.double(forKey: "cloud_sync_last_success")
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }
    private func setResult(_ value: Result) {
        result = value
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    var resultText: String {
        switch result {
        case .idle: return SetupCopy.text("等待同步", "Waiting to sync")
        case .disabled: return SetupCopy.text("Debug 版本不写入 iCloud", "Debug builds do not write to iCloud")
        case .syncing: return SetupCopy.text("正在同步摘要…", "Syncing summaries…")
        case .succeeded: return SetupCopy.text("摘要同步成功", "Summaries synced successfully")
        case .failed: return SetupCopy.text("摘要同步失败，可稍后重试", "Summary sync failed; retry later")
        }
    }
    func refreshAccount() async {
        guard Self.allowsCloudWrites else {
            accountText = SetupCopy.text("Debug 版本不连接 iCloud", "Debug builds do not connect to iCloud")
            setResult(.disabled)
            return
        }
        do {
            let account = try await CKContainer(identifier: "iCloud.com.wxy.aipulse").accountStatus()
            switch account {
            case .available: accountText = SetupCopy.text("iCloud 账户可用", "iCloud account available")
            case .noAccount: accountText = SetupCopy.text("尚未登录 iCloud", "Not signed in to iCloud")
            case .restricted: accountText = SetupCopy.text("iCloud 访问受限", "iCloud access restricted")
            default: accountText = SetupCopy.text("暂时无法确认 iCloud 状态", "iCloud status temporarily unavailable")
            }
        } catch { accountText = SetupCopy.text("无法连接 iCloud，稍后重试", "Cannot connect to iCloud; retry later") }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

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
            setResult(.disabled)
            Logger.info("CloudSync: dashboard writes disabled in Debug")
            return
        }

        guard result != .syncing else { return }
        setResult(.syncing)
        var didFail = false
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
                guard let period = DashboardPeriodKind(rawValue: r.key) else { didFail = true; continue }
                snap = await StatsService.dashboardSnapshot(period: period)
            }
            guard let data = try? JSONEncoder().encode(snap),
                  let json = String(data: data, encoding: .utf8) else { didFail = true; continue }

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
                    Logger.info("CloudSync: synced \(CKSchema.recordType)/\(r.recordName) len=\(json.count)")
                    lastSyncedFingerprint[r.key] = fingerprint
                } else { didFail = true }
            } catch {
                didFail = true
                Logger.error("CloudSync: \(r.key) save failed: \(error)")
            }
        }
        if !(await syncCurrentPulse()) { didFail = true }
        if !didFail { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "cloud_sync_last_success") }
        setResult(didFail ? .failed : .succeeded)
    }

    private func syncCurrentPulse() async -> Bool {
        let now = Date()
        let pulse = await PulseEngine.shared.snapshot()
        let availability = LocalDataStatus.current(hasActivity: (pulse?.activityFacts?.todayTokens ?? 0) > 0)
        let envelope = CurrentPulseEnvelope(pulse: availability.canReportCurrentActivity ? pulse : nil,
                                            writerAppVersion: CKSchema.writerAppVersion, generatedAt: now)
        guard let data = try? JSONEncoder().encode(envelope),
              let json = String(data: data, encoding: .utf8) else { return false }
        let record = CKRecord(recordType: CKSchema.CurrentPulse.recordType,
                              recordID: CKRecord.ID(recordName: CKSchema.CurrentPulse.recordName))
        record[CKSchema.Field.json] = json
        record[CKSchema.Field.updatedAt] = now
        do {
            let (_, results) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            var success = true
            for (_, result) in results {
                if case .failure(let error) = result { success = false; Logger.error("CloudSync current pulse record failed: \(error)") }
            }
            if success { Logger.info("CloudSync: synced \(CKSchema.CurrentPulse.recordType)/\(CKSchema.CurrentPulse.recordName)") }
            return success
        } catch {
            Logger.error("CloudSync current pulse failed: \(error)")
            return false
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
