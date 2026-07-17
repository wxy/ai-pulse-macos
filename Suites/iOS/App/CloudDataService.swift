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
               let data = json.data(using: .utf8),
               let snap = try? JSONDecoder().decode(DashboardSnapshot.self, from: data) {
                snapshot = snap
                lastUpdated = record["updatedAt"] as? Date
                return true
            }
            log.warning("hasData: json parse failed")
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
