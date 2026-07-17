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
        let recordID = CKRecord.ID(recordName: "snapshot")
        do {
            let record = try await database.record(for: recordID)
            // New format: version + json fields
            if let json = record["json"] as? String,
               let data = json.data(using: .utf8),
               let snap = try? JSONDecoder().decode(DashboardSnapshot.self, from: data) {
                snapshot = snap
                lastUpdated = record["updatedAt"] as? Date
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func fetchSnapshot() async throws {
        _ = try await hasData()
    }
}
