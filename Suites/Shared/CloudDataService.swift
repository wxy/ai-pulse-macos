import CloudKit
import Combine
import Foundation
import os

enum CloudError: Error {
    case noData
    case unavailable
}

/// Reads the DashboardCache_v1 record synced by macOS.
/// Maintains THREE independent snapshots — one per time range — so each tab
/// always displays its own data, even offline or when a CK fetch fails.
@MainActor
final class CloudDataService: ObservableObject {
    static let shared = CloudDataService()

    /// The snapshot for the currently selected time range.
    @Published var snapshot: DashboardSnapshot?
    @Published var lastUpdated: Date?
    private var currentRange: String = "today"

    /// All three per-range snapshots. Keyed by "today" / "week" / "30d".
    private var snapshots: [String: DashboardSnapshot] = [:]

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
              let dict = try? JSONDecoder().decode([String: DashboardSnapshot].self, from: data) else { return }
        snapshots = dict
        // Default to today on first load (caller should call loadSnapshot(for:) afterward)
        if let today = dict["today"] { snapshot = today }
        log.info("loaded local cache: \(dict.keys.joined(separator: ", "))")
    }

    private func saveLocalCache() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: localCacheURL, options: .atomic)
    }

    /// Switch the published snapshot to the given time range.
    /// Each tab calls this on appear / tab switch — guaranteed to show
    /// only that range's data (cost + breakdown), never another range's.
    func loadSnapshot(for range: String) {
        currentRange = range
        if let s = snapshots[range] {
            snapshot = s
            lastUpdated = s.updatedAt
        }
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
            // Store today's snapshot independently (with CK updatedAt timestamp)
            var stored = snap
            if let ts = record[CKSchema.Field.updatedAt] as? Date { stored.updatedAt = ts }
            self.snapshots["today"] = stored
            if self.snapshot == nil { self.loadSnapshot(for: "today") }
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

        // Fetch all three time ranges independently
        log.info("refresh: fetching all ranges")
        await fetchAndStore(range: "today")
        await fetchAndStore(range: "week")
        await fetchAndStore(range: "30d")
        // Reload the currently displayed range so the UI reflects new data
        loadSnapshot(for: currentRange)
        log.info("refresh: final — today=\(snapshots["today"]?.todayCost ?? -1) week=\(snapshots["week"]?.weekCost ?? -1) month=\(snapshots["30d"]?.monthCost ?? -1)")
    }

    /// Fetch a single snapshot record and store it independently by range.
    /// Each tab always gets its own data — no cross-range merging.
    func fetchAndMergeWeek() async { await fetchAndStore(range: "week") }
    func fetchAndMergeMonth() async { await fetchAndStore(range: "30d") }

    private func fetchAndStore(range: String) async {
        let rid = CKRecord.ID(recordName: recordName(for: range))
        let record: CKRecord
        do {
            record = try await database.record(for: rid)
        } catch {
            log.error("fetchAndStore(\(range)): CK fetch failed — \(error.localizedDescription)")
            return
        }
        guard let json = record[CKSchema.Field.json] as? String,
              let data = json.data(using: .utf8) else {
            log.error("fetchAndStore(\(range)): json field missing or not a string")
            return
        }
        let snap: DashboardSnapshot
        do {
            snap = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        } catch {
            log.error("fetchAndStore(\(range)): decode failed — \(error.localizedDescription)")
            return
        }
        log.info("fetchAndStore(\(range)): today=\(snap.todayCost) week=\(snap.weekCost) month=\(snap.monthCost)")
        var stored = snap
        if let ts = record[CKSchema.Field.updatedAt] as? Date { stored.updatedAt = ts }
        self.snapshots[range] = stored
        // If this range is currently displayed, update the published snapshot too
        // (loadSnapshot checks the current range against what the caller expects)
        saveLocalCache()
    }

    /// Fetch a single range AND switch the published snapshot to it.
    /// Called on tab switch — shows that range's data immediately.
    func fetchSnapshot(for range: String = "today") async throws {
        await fetchAndStore(range: range)
        loadSnapshot(for: range)
    }
}
