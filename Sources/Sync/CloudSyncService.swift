import CloudKit
import Foundation
import AIPulseShared

/// Syncs the cached dashboard snapshots from GRDB to iCloud.
/// iOS/watchOS read per-range snapshots to display correct data per tab.
@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    /// Construct CKContainer only when a signed app needs CloudKit.
    /// Unsigned SwiftPM builds and tests have no CloudKit access.
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
        case .disabled: return SetupCopy.text("此构建未启用 iCloud 权限", "Cloud access is not enabled in this build")
        case .syncing: return SetupCopy.text("正在同步摘要…", "Syncing summaries…")
        case .succeeded: return SetupCopy.text("摘要同步成功", "Summaries synced successfully")
        case .failed: return SetupCopy.text("摘要同步失败，可稍后重试", "Summary sync failed; retry later")
        }
    }
    func refreshAccount() async {
        guard Self.allowsCloudWrites else {
            accountText = SetupCopy.text("此构建未启用 iCloud 权限", "Cloud access is not enabled in this build")
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

    static func allowsCloudWrites(signingEnabled: String?) -> Bool {
        signingEnabled?.uppercased() == "YES"
    }

    private static var allowsCloudWrites: Bool {
        allowsCloudWrites(signingEnabled: Bundle.main.object(forInfoDictionaryKey: "CloudKitAccessEnabled") as? String)
    }

    /// Content fingerprint (updatedAt excluded) of the last snapshot actually
    /// written per range. Used to skip no-op CloudKit writes — see
    /// `syncFromCache()`.
    private var lastSyncedFingerprint: [String: Int] = [:]

    private init() {}

    func syncFromCache(publishMacWidget: Bool = true) async {
        let cloudEnabled = Self.allowsCloudWrites
        guard publishMacWidget || cloudEnabled else {
            setResult(.disabled)
            return
        }
        if cloudEnabled {
            guard result != .syncing else { return }
            setResult(.syncing)
        }

        // The dashboard can request sync before startup log replay completes.
        // Wait for that queued scan without starting another one, so the
        // snapshots published to the widget and CloudKit include its facts.
        if !RuntimeQA.isEnabled { await LogWatcher.shared.waitForPendingScan() }

        // Resolve each range once for this sync. The widget and CloudKit must
        // not each rebuild 30 days after a usage event cleared the cache.
        let today = await snapshot(for: .today, maxAge: 600)
        let history = await snapshot(for: .days30, maxAge: 43200)
        if publishMacWidget {
            _ = await MacWidgetLocalPublisher.publish(todaySnapshot: today, historySnapshot: history)
        }

        guard cloudEnabled else {
            setResult(.disabled)
            Logger.info("CloudSync: dashboard writes disabled in this unsigned build")
            return
        }

        var didFail = false
        Logger.info("CloudSync: starting sync")
        let ranges: [(key: String, recordName: String, maxAge: TimeInterval)] = [
            ("today", CKSchema.RecordName.today, 600),
            ("week", CKSchema.RecordName.week, 3600),
            ("30d", CKSchema.RecordName.month, 43200),
        ]
        for r in ranges {
            let snap: DashboardSnapshot
            switch r.key {
            case DashboardPeriodKind.today.rawValue: snap = today
            case DashboardPeriodKind.days30.rawValue: snap = history
            default: snap = await snapshot(for: .week, maxAge: r.maxAge)
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

    private func snapshot(for period: DashboardPeriodKind, maxAge: TimeInterval) async -> DashboardSnapshot {
        if let cached = await DashboardCache.read(timeRange: period.rawValue, maxAge: maxAge) {
            return cached
        }
        return await StatsService.dashboardSnapshot(period: period)
    }

    private func syncCurrentPulse() async -> Bool {
        let now = Date()
        let pulse = await PulseEngine.shared.snapshot()
        let availability = LocalDataStatus.current(hasActivity: (pulse?.activityFacts?.todayTokens ?? 0) > 0)
        guard availability.canReportCurrentActivity,
              let pulse,
              pulse.isCurrent(asOf: now) else {
            // Do not erase the last truthful observation with an unavailable
            // one. Readers can keep showing it with its original timestamp.
            Logger.info("CloudSync: current pulse unavailable; preserving last observation")
            return true
        }
        let envelope = CurrentPulseEnvelope.forCloudSync(
            pulse: pulse,
            writerAppVersion: CKSchema.writerAppVersion,
            generatedAt: now
        )
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
            Logger.info("CloudSync: spend-alert CloudKit write disabled in this unsigned build")
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
