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

    private let database = CKContainer.default().privateCloudDatabase
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
            print("hasData: record found, json present=\(record[CKSchema.Field.json] != nil)")
            if let json = record[CKSchema.Field.json] as? String,
               let data = json.data(using: .utf8) {
                do {
                    let snap = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
                    snapshot = snap
                    lastUpdated = record[CKSchema.Field.updatedAt] as? Date
                    return true
                } catch {
                    print("hasData: decode failed — \(error.localizedDescription)")
                    if let dc = error as? DecodingError {
                        switch dc {
                        case .keyNotFound(let key, _): print("  missing key: \(key.stringValue)")
                        case .typeMismatch(let t, let ctx): print("  type mismatch: \(String(describing: t)) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                        default: break
                        }
                    }
                    throw CloudError.noData
                }
            }
            print("hasData: json field missing")
            throw CloudError.noData
        } catch let cloudError as CloudError {
            throw cloudError
        } catch let ckError as CKError {
            switch ckError.code {
            case .unknownItem:
                throw CloudError.noData
            case .networkUnavailable, .notAuthenticated, .permissionFailure:
                print("hasData: iCloud unavailable — \(ckError.localizedDescription)")
                throw CloudError.unavailable
            default:
                print("hasData: CKError — \(ckError.localizedDescription)")
                throw CloudError.unavailable
            }
        } catch {
            print("hasData: \(error.localizedDescription)")
            throw CloudError.unavailable
        }
    }

    /// Lightweight refresh for watchOS — fetch today snapshot, silently ignore errors.
    func refresh() async {
        do {
            // Check iCloud account status first
            let status = try await CKContainer.default().accountStatus()
            switch status {
            case .available:
                break
            case .noAccount:
                print("refresh: no iCloud account")
                return
            case .restricted:
                print("refresh: iCloud restricted")
                return
            case .couldNotDetermine:
                print("refresh: could not determine iCloud status")
                return
            case .temporarilyUnavailable:
                print("refresh: iCloud temporarily unavailable")
                return
            @unknown default:
                print("refresh: unknown iCloud status")
                return
            }
            try await fetchSnapshot(for: "today")
        } catch let ckError as CKError {
            print("refresh: CKError code=\(ckError.code.rawValue) — \(ckError.localizedDescription)")
        } catch {
            print("refresh: \(error.localizedDescription)")
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
            print("fetchSnapshot(\(range)): \(error.localizedDescription)")
        }
    }
}
