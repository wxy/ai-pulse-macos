import Foundation
import GRDB
import AIPulseShared

/// Cached dashboard snapshot — computed in load() and persisted to GRDB.
/// Each time range (today/week/30d) gets its own row.
/// Uses raw SQL to avoid GRDB protocol conformance actor-isolation issues.
struct DashboardCache {
    var timeRange: String
    var json: String
    var updatedAt: Date

    static func write(timeRange: String, json: String) async {
        do {
            try await AppDatabase.shared.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO dashboard_cache (time_range, json, updated_at)
                    VALUES (?, ?, ?)
                    """, arguments: [timeRange, json, Date()])
            }
        } catch {
            Logger.warning("Dashboard: cache write failed — \(error.localizedDescription)")
        }
    }

    /// Removes all cached snapshots.
    ///
    /// Called when a new balance snapshot lands — API spend feeds every
    /// dashboard range, and the per-range caches refresh at different rates
    /// (today=5min, week=1h, 30d=12h). Without invalidation a fresh balance
    /// delta shows up on Today within minutes while This Week keeps serving
    /// the pre-poll snapshot for up to an hour.
    static func invalidateAll() async {
        do {
            try await AppDatabase.shared.write { db in
                try db.execute(sql: "DELETE FROM dashboard_cache")
            }
        } catch {
            Logger.warning("Dashboard: cache invalidation failed — \(error.localizedDescription)")
        }
    }

    static func read(timeRange: String, maxAge: TimeInterval = 30) async -> DashboardSnapshot? {
        do {
            let cached = try await AppDatabase.shared.read { db -> (json: String, updatedAt: Date)? in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT json, updated_at FROM dashboard_cache WHERE time_range = ?
                    """, arguments: [timeRange]),
                      let json: String = row["json"],
                      let updatedAt: Date = row["updated_at"]
                else { return nil }
                return (json, updatedAt)
            }
            guard let cached,
                  -cached.updatedAt.timeIntervalSinceNow < maxAge
            else { return nil }
            let json = cached.json
            guard
                  let data = json.data(using: .utf8),
                  let snap = try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
            else { return nil }
            return snap
        } catch {
            return nil
        }
    }
}
