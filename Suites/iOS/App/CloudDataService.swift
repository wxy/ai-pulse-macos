import CloudKit
import Combine
import Foundation

/// Reads the single DashboardSummary record synced by macOS.
@MainActor
final class CloudDataService: ObservableObject {
    static let shared = CloudDataService()

    @Published var todayCost: Double = 0
    @Published var weekCost: Double = 0
    @Published var monthCost: Double = 0
    @Published var providerBreakdown: [(providerId: String, name: String, cost: Double)] = []
    @Published var topRepos: [(name: String, cost: Double)] = []
    @Published var weekTrend: [(date: Date, cost: Double)] = []

    private let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase

    private init() {}

    func hasData() async throws -> Bool {
        let recordID = CKRecord.ID(recordName: "dashboard-summary")
        do {
            _ = try await database.record(for: recordID)
            return true
        } catch {
            print("[CloudData] hasData: no summary record yet — \(error.localizedDescription)")
            return false
        }
    }

    func fetchAll() async throws {
        let recordID = CKRecord.ID(recordName: "dashboard-summary")
        let record = try await database.record(for: recordID)

        todayCost = record["todayCost"] as? Double ?? 0
        weekCost = record["weekCost"] as? Double ?? 0
        monthCost = record["monthCost"] as? Double ?? 0
        providerBreakdown = parseJSONArray(record["providerBreakdown"] as? String ?? "").map {
            (providerId: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", cost: $0["cost"] as? Double ?? 0)
        }
        topRepos = parseJSONArray(record["topRepos"] as? String ?? "").map {
            (name: $0["name"] as? String ?? "", cost: $0["cost"] as? Double ?? 0)
        }
        weekTrend = parseJSONArray(record["weekTrend"] as? String ?? "").compactMap {
            guard let ds = $0["date"] as? String, let date = ISO8601DateFormatter().date(from: ds),
                  let cost = $0["cost"] as? Double else { return nil }
            return (date: date, cost: cost)
        }
    }

    private func parseJSONArray(_ str: String) -> [[String: Any]] {
        guard let data = str.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array
    }
}
