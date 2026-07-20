import CloudKit
import Combine
import Foundation
import os

enum CloudError: Error {
    case noData
    case unavailable
}

/// Reads the DashboardCache_v1 record synced by macOS.
@MainActor
final class CloudDataService: ObservableObject {
    static let shared = CloudDataService()

    @Published var snapshot: DashboardSnapshot?
    @Published var lastUpdated: Date?

    private lazy var database: CKDatabase = {
        let db = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase
        return db
    }()
    private let log = Logger(subsystem: "com.wxy.aipulse", category: "CloudData")
    private init() {
        loadLocalCache()
    }

    // MARK: - Local cache (survives offline / app restart)

    private var localCacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("dashboard_cache.json")
    }

    private func loadLocalCache() {
        guard let data = try? Data(contentsOf: localCacheURL),
              let snap = try? JSONDecoder().decode(DashboardSnapshot.self, from: data) else { return }
        snapshot = snap
        lastUpdated = snap.updatedAt
        log.info("loaded local cache: today=\(snap.todayCost) week=\(snap.weekCost) month=\(snap.monthCost)")
    }

    private func saveLocalCache() {
        guard let snap = snapshot,
              let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: localCacheURL, options: .atomic)
    }

    private func recordName(for range: String) -> String {
        switch range {
        case "today": return CKSchema.RecordName.today
        case "week":  return CKSchema.RecordName.week
        case "30d":   return CKSchema.RecordName.month
        default:      return "snapshot-\(range)"
        }
    }

    /// Check if CloudKit has data. On success, merge the today record's costs
    /// into the current snapshot WITHOUT replacing breakdown data (repos, trends).
    /// This preserves previously-cached week/30d breakdowns if they can't be
    /// refreshed right now.
    func hasData() async throws -> Bool {
        let recordID = CKRecord.ID(recordName: recordName(for: "today"))
        do {
            let record = try await database.record(for: recordID)
            log.info("hasData: record found, json present=\(record[CKSchema.Field.json] != nil)")
            guard let json = record[CKSchema.Field.json] as? String,
                  let data = json.data(using: .utf8) else {
                log.warning("hasData: json field missing")
                throw CloudError.noData
            }
            let snap: DashboardSnapshot
            do {
                snap = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
            } catch {
                log.error("hasData: decode failed — \(error.localizedDescription)")
                throw CloudError.noData
            }
            // Merge today's costs into any existing snapshot (local cache), keeping
            // breakdown data intact. First launch: snapshot starts empty, gets today's data.
            var merged = self.snapshot ?? DashboardSnapshot()
            if snap.todayCost > 0 { merged.todayCost = snap.todayCost }
            if snap.weekCost > 0 { merged.weekCost = snap.weekCost }
            if snap.monthCost > 0 { merged.monthCost = snap.monthCost }
            if snap.yesterdaySpend > 0 { merged.yesterdaySpend = snap.yesterdaySpend }
            if snap.previousPeriodSpend > 0 { merged.previousPeriodSpend = snap.previousPeriodSpend }
            if let p = snap.prediction { merged.prediction = p }
            // Only set breakdown if we don't already have it (first launch)
            if self.snapshot == nil {
                merged.topRepos = snap.topRepos
                merged.dailyStats = snap.dailyStats
                merged.codeChanges = snap.codeChanges
                merged.balanceDaily = snap.balanceDaily
                merged.providerBreakdown = snap.providerBreakdown
                merged.toolBreakdown = snap.toolBreakdown
                merged.todayCalls = snap.todayCalls
                merged.todayTokens = snap.todayTokens
                merged.subDaily = snap.subDaily
            }
            if let ts = record[CKSchema.Field.updatedAt] as? Date { merged.updatedAt = ts }
            self.snapshot = merged
            self.lastUpdated = merged.updatedAt
            saveLocalCache()
            return true
        } catch let cloudError as CloudError {
            throw cloudError
        } catch let ckError as CKError {
            log.error("hasData: CKError code=\(ckError.code.rawValue) userInfo=\(ckError.errorUserInfo)")
            switch ckError.code {
            case .unknownItem:
                throw CloudError.noData
            case .networkUnavailable, .notAuthenticated, .permissionFailure:
                throw CloudError.unavailable
            default:
                throw CloudError.unavailable
            }
        } catch {
            log.error("hasData: \(error.localizedDescription)")
            throw CloudError.unavailable
        }
    }

    /// Lightweight refresh for watchOS — fetch today snapshot with detailed error reporting.
    func refresh() async {
        let container = CKContainer(identifier: "iCloud.com.wxy.aipulse")
        log.info("refresh: container=\(container.containerIdentifier ?? "nil")")

        do {
            let status = try await container.accountStatus()
            log.info("refresh: account status=\(status.rawValue)")
            switch status {
            case .available: break
            case .noAccount:       log.error("refresh: no iCloud account"); return
            case .restricted:      log.error("refresh: iCloud restricted"); return
            case .couldNotDetermine: log.error("refresh: could not determine iCloud status"); return
            case .temporarilyUnavailable: log.error("refresh: iCloud temporarily unavailable"); return
            @unknown default:      log.error("refresh: unknown iCloud status \(status.rawValue)"); return
            }
        } catch {
            log.error("refresh: accountStatus() threw — \(error.localizedDescription)")
            return
        }

        // Fetch all three time ranges and merge into a complete snapshot
        log.info("refresh: fetching all ranges")
        await fetchAndMerge(range: "today", mergeBreakdown: false)
        await fetchAndMerge(range: "week", mergeBreakdown: false)
        await fetchAndMerge(range: "30d", mergeBreakdown: false)
        log.info("refresh: final — today=\(self.snapshot?.todayCost ?? -1) week=\(self.snapshot?.weekCost ?? -1) month=\(self.snapshot?.monthCost ?? -1)")
    }

    /// Fetch a single snapshot record and merge it into self.snapshot.
    func fetchAndMergeWeek() async { await fetchAndMerge(range: "week", mergeBreakdown: false) }
    func fetchAndMergeMonth() async { await fetchAndMerge(range: "30d", mergeBreakdown: false) }

    private func fetchAndMerge(range: String, mergeBreakdown: Bool) async {
        let rid = CKRecord.ID(recordName: recordName(for: range))
        let record: CKRecord
        do {
            record = try await database.record(for: rid)
        } catch {
            log.error("fetchAndMerge(\(range)): CK fetch failed — \(error.localizedDescription)")
            return
        }
        let rawValue = record[CKSchema.Field.json]
        log.info("fetchAndMerge(\(range)): json field type = \(type(of: rawValue))")
        guard let json = rawValue as? String else {
            log.error("fetchAndMerge(\(range)): json field is not String — type=\(type(of: rawValue)), value=\(String(describing: rawValue).prefix(200))")
            return
        }
        guard let data = json.data(using: .utf8) else {
            log.error("fetchAndMerge(\(range)): json utf8 encoding failed")
            return
        }
        let snap: DashboardSnapshot
        do {
            snap = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        } catch let dc as DecodingError {
            log.error("fetchAndMerge(\(range)): decode error — \(String(describing: dc))")
            // Dump raw JSON to see what's actually in the record
            let preview = String(json.prefix(200))
            log.error("fetchAndMerge(\(range)): raw JSON preview: \(preview)")
            return
        } catch {
            log.error("fetchAndMerge(\(range)): decode failed — \(error.localizedDescription)")
            return
        }
        log.info("fetchAndMerge(\(range)): today=\(snap.todayCost) week=\(snap.weekCost) month=\(snap.monthCost) yday=\(snap.yesterdaySpend)")
        var merged = self.snapshot ?? DashboardSnapshot()

        // Always merge cross-range costs (each from its own CK record).
        // Breakdown data (repos, trends, tools) is NOT merged here — it comes
        // from fetchSnapshot(for:) when the user switches tabs, so each tab
        // shows its own range's breakdown.
        if snap.todayCost > 0 { merged.todayCost = snap.todayCost }
        if snap.weekCost > 0 { merged.weekCost = snap.weekCost }
        if snap.monthCost > 0 { merged.monthCost = snap.monthCost }
        if snap.yesterdaySpend > 0 { merged.yesterdaySpend = snap.yesterdaySpend }
        if snap.previousPeriodSpend > 0 { merged.previousPeriodSpend = snap.previousPeriodSpend }
        if let p = snap.prediction { merged.prediction = p }

        // Only merge breakdown data when explicitly fetching for a specific tab
        // (e.g. user switches tabs). Background refreshes (refresh()) merge costs
        // only, so breakdown from one range doesn't overwrite another.
        if mergeBreakdown {
            if !snap.topRepos.isEmpty { merged.topRepos = snap.topRepos }
            if !snap.dailyStats.isEmpty { merged.dailyStats = snap.dailyStats }
            if !snap.codeChanges.isEmpty { merged.codeChanges = snap.codeChanges }
            if !snap.balanceDaily.isEmpty { merged.balanceDaily = snap.balanceDaily }
            if !snap.providerBreakdown.isEmpty { merged.providerBreakdown = snap.providerBreakdown }
            if !snap.toolBreakdown.isEmpty { merged.toolBreakdown = snap.toolBreakdown }
            merged.todayCalls = snap.todayCalls
            merged.todayTokens = snap.todayTokens
            merged.subDaily = snap.subDaily
        }

        if let ts = record[CKSchema.Field.updatedAt] as? Date { merged.updatedAt = ts }
        self.snapshot = merged
        self.lastUpdated = merged.updatedAt
        saveLocalCache()
    }

    /// Fetch a single range and merge costs + breakdown into the current snapshot.
    /// Breakdown is merged because this is a user-initiated tab switch — the
    /// displayed repos/trends should reflect the selected range.
    func fetchSnapshot(for range: String = "today") async throws {
        await fetchAndMerge(range: range, mergeBreakdown: true)
    }
}
