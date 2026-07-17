import CloudKit
import Combine
import Foundation
import os

/// Reads the DashboardCache_v1 record synced by macOS.
@MainActor
final class CloudDataService: ObservableObject {
    static let shared = CloudDataService()

    @Published var snapshot: DashboardSnapshot?
    @Published var lastUpdated: Date?

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase
    private let log = Logger(subsystem: "com.wxy.aipulse", category: "CloudData")

    private init() {}

    func hasData() async throws -> Bool {
        let recordID = CKRecord.ID(recordName: "snapshot")
        do {
            let record = try await database.record(for: recordID)
            log.info("hasData: record found, json present=\(record["json"] != nil)")
            if let json = record["json"] as? String,
               let data = json.data(using: .utf8) {
                do {
                    let snap = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
                    snapshot = snap
                    lastUpdated = record["updatedAt"] as? Date
                    return true
                } catch {
                    log.error("hasData: decode failed — \(error.localizedDescription)")
                    if let dc = error as? DecodingError {
                        switch dc {
                        case .keyNotFound(let key, _): log.error("  missing key: \(key.stringValue)")
                        case .typeMismatch(let t, let ctx): log.error("  type mismatch: \(String(describing: t)) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                        default: break
                        }
                    }
                    return false
                }
            }
            log.warning("hasData: json field missing")
            return false
        } catch {
            log.error("hasData: \(error.localizedDescription)")
            return false
        }
    }

    func fetchSnapshot() async throws {
        _ = try await hasData()
    }
}
