import CloudKit
import Combine
import Foundation

/// Reads the DashboardSnapshot_v1 record synced by macOS.
@MainActor
final class CloudDataService: ObservableObject {
    static let shared = CloudDataService()

    @Published var snapshot: DashboardSnapshot?
    @Published var lastUpdated: Date?

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase

    private init() {}

    func hasData() async throws -> Bool {
        let recordID = CKRecord.ID(recordName: "dashboard-snapshot")
        do {
            _ = try await database.record(for: recordID)
            return true
        } catch {
            return false
        }
    }

    func fetchSnapshot() async throws {
        let recordID = CKRecord.ID(recordName: "dashboard-snapshot")
        let record = try await database.record(for: recordID)

        guard let jsonStr = record["json"] as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let snap = try? JSONDecoder().decode(DashboardSnapshot.self, from: jsonData)
        else { return }

        snapshot = snap
        lastUpdated = record["updatedAt"] as? Date
    }
}
