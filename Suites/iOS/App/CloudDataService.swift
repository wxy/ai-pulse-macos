import CloudKit
import Combine
import Foundation
import os.log

/// Reads aggregated spending data from iCloud Private DB (synced by macOS).
@MainActor
final class CloudDataService: ObservableObject {
    static let shared = CloudDataService()

    @Published var dailyStats: [DailyStat] = []
    @Published var codeChanges: [DailyCodeChange] = []
    @Published var providerCosts: [ProviderCost] = []

    private let container = CKContainer(identifier: "iCloud.com.wxy.aipulse")
    private let database: CKDatabase

    private init() {
        database = container.privateCloudDatabase
    }

    /// Check if any data exists in iCloud (for welcome → dashboard transition).
    func hasData() async throws -> Bool {
        // Query on a queryable field to avoid 'recordName not queryable'
        let predicate = NSPredicate(format: "cost > 0")
        let query = CKQuery(recordType: CKRecordType.dailyStat.rawValue, predicate: predicate)
        let (results, _) = try await database.records(matching: query, resultsLimit: 1)
        print("[CloudData] hasData: \(results.count) results")
        return !results.isEmpty
    }

    /// Fetch pre-computed totals (today/week/month) from the AppConfig record.
    func fetchTotals() async -> (today: Double, week: Double, month: Double) {
        do {
            let recordID = CKRecord.ID(recordName: "app-config")
            let record = try await database.record(for: recordID)
            let today = record["todayCost"] as? Double ?? 0
            let week = record["weekCost"] as? Double ?? 0
            let month = record["monthCost"] as? Double ?? 0
            return (today, week, month)
        } catch {
            print("[CloudData] fetchTotals error: \(error)")
            return (0, 0, 0)
        }
    }

    /// Fetch all data for the given time range.
    func fetchAll(days: Int) async throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!

        // Fetch daily stats
        dailyStats = try await fetchDailyStats(since: cutoff)
        codeChanges = try await fetchCodeChanges(since: cutoff)
        providerCosts = try await fetchProviderCosts(since: cutoff)
    }

    // MARK: - Private fetches

    private func fetchDailyStats(since cutoff: Date) async throws -> [DailyStat] {
        let predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
        let query = CKQuery(recordType: CKRecordType.dailyStat.rawValue, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKField.date, ascending: false)]

        let (results, _) = try await database.records(matching: query, resultsLimit: 30)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return DailyStat(
                date: record[CKField.date] as? Date ?? Date(),
                cost: record[CKField.cost] as? Double ?? 0,
                calls: record[CKField.calls] as? Int ?? 0,
                tokens: record[CKField.tokens] as? Int ?? 0,
                netLines: record[CKField.netLines] as? Int ?? 0,
                costPerLine: record[CKField.costPerLine] as? Double ?? 0
            )
        }
    }

    private func fetchCodeChanges(since cutoff: Date) async throws -> [DailyCodeChange] {
        let predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
        let query = CKQuery(recordType: CKRecordType.dailyCodeChange.rawValue, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKField.date, ascending: false)]

        let (results, _) = try await database.records(matching: query, resultsLimit: 30)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return DailyCodeChange(
                date: record[CKField.date] as? Date ?? Date(),
                added: record[CKField.added] as? Int ?? 0,
                deleted: record[CKField.deleted] as? Int ?? 0
            )
        }
    }

    private func fetchProviderCosts(since cutoff: Date) async throws -> [ProviderCost] {
        let predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
        let query = CKQuery(recordType: CKRecordType.providerCost.rawValue, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKField.date, ascending: false)]

        let (results, _) = try await database.records(matching: query, resultsLimit: 50)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return ProviderCost(
                date: record[CKField.date] as? Date ?? Date(),
                providerId: record[CKField.providerId] as? String ?? "",
                cost: record[CKField.cost] as? Double ?? 0
            )
        }
    }
}
