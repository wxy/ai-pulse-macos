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

        do {
            try await fetchSnapshot(for: "today")
            log.info("refresh: snapshot fetched, cost=\(self.snapshot?.todayCost ?? -1)")
        } catch let ckError as CKError {
            log.error("refresh: CKError code=\(ckError.code.rawValue) userInfo=\(ckError.errorUserInfo)")
        } catch {
            log.error("refresh: \(error.localizedDescription)")
        }
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
