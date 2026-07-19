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
    private init() {}

    private func recordName(for range: String) -> String {
        switch range {
        case "today": return CKSchema.RecordName.today
        case "week":  return CKSchema.RecordName.week
        case "30d":   return CKSchema.RecordName.month
        default:      return "snapshot-\(range)"
        }
    }

    func hasData() async throws -> Bool {
        let recordID = CKRecord.ID(recordName: recordName(for: "today"))
        do {
            let record = try await database.record(for: recordID)
            log.info("hasData: record found, json present=\(record[CKSchema.Field.json] != nil)")
            if let json = record[CKSchema.Field.json] as? String,
               let data = json.data(using: .utf8) {
                do {
                    let snap = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
                    snapshot = snap
                    lastUpdated = record[CKSchema.Field.updatedAt] as? Date
                    return true
                } catch {
                    log.error("hasData: decode failed — \(error.localizedDescription)")
                    throw CloudError.noData
                }
            }
            log.warning("hasData: json field missing")
            throw CloudError.noData
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
        await fetchAndMerge(range: "today")
        await fetchAndMerge(range: "week")
        await fetchAndMerge(range: "30d")
        log.info("refresh: final — today=\(self.snapshot?.todayCost ?? -1) week=\(self.snapshot?.weekCost ?? -1) month=\(self.snapshot?.monthCost ?? -1)")
    }

    /// Fetch a single snapshot record and merge it into self.snapshot.
    func fetchAndMergeWeek() async { await fetchAndMerge(range: "week") }
    func fetchAndMergeMonth() async { await fetchAndMerge(range: "30d") }

    private func fetchAndMerge(range: String) async {
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

        // Only merge fields relevant to each range to avoid overwriting fresh data with stale
        switch range {
        case "today":
            if snap.todayCost > 0 { merged.todayCost = snap.todayCost }
            if snap.yesterdaySpend > 0 { merged.yesterdaySpend = snap.yesterdaySpend }
        case "week":
            if snap.weekCost > 0 { merged.weekCost = snap.weekCost }
        case "30d":
            if snap.monthCost > 0 { merged.monthCost = snap.monthCost }
            if let p = snap.prediction { merged.prediction = p }
        default: break
        }
        if let ts = record[CKSchema.Field.updatedAt] as? Date { merged.updatedAt = ts }
        self.snapshot = merged
        self.lastUpdated = merged.updatedAt
    }

    func fetchSnapshot(for range: String = "today") async throws {
        let recordID = CKRecord.ID(recordName: recordName(for: range))
        do {
            let record = try await database.record(for: recordID)
            if let json = record[CKSchema.Field.json] as? String,
               let data = json.data(using: .utf8) {
                let snap = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
                snapshot = snap
                lastUpdated = record[CKSchema.Field.updatedAt] as? Date
            }
        } catch {
            log.error("fetchSnapshot(\(range)): \(error.localizedDescription)")
        }
    }
}
