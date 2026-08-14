import Foundation
import GRDB

final class AppDatabase: @unchecked Sendable {
    static let shared = AppDatabase()
    private var dbQueue: DatabaseQueue?

    func setup() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dbDir = appSupport.appendingPathComponent("AIPulse")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("aipulse.db").path
        dbQueue = try DatabaseQueue(path: dbPath)
        Logger.info("DB opened at \(dbPath)")

        try dbQueue?.write { try AppDatabase.createAllTables($0) }

        // Additive column migrations for existing installs
        // (create-ifNotExists won't add columns to tables that already exist).
        addColumnIfMissing("quota_status", "window_seconds", "REAL")
        Logger.info("DB migration complete")
    }

    /// All table migrations, in dependency order. Exposed as a static so
    /// tests can run the same schema against an in-memory database.
    static func createAllTables(_ db: Database) throws {
        for (_, migration) in tables {
            try migration(db)
        }
    }

    private static nonisolated(unsafe) let tables: [(String, (Database) throws -> Void)] = [
            ("usage_event", { db in
                try db.create(table: "usage_event", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("ts", .integer).notNull()
                    t.column("source", .text).notNull()
                    t.column("provider_id", .text)
                    t.column("model", .text)
                    t.column("in_tokens", .integer).defaults(to: 0)
                    t.column("out_tokens", .integer).defaults(to: 0)
                    t.column("cache_tokens", .integer).defaults(to: 0)
                    t.column("cost_usd", .double)
                    t.column("repo_path", .text)
                    t.column("session_id", .text)
                    t.column("dedupe_key", .text).unique()
                    t.column("cost_source_id", .text)
                    t.column("cost_confidence", .text).defaults(to: "estimated")
                }
                try? db.create(indexOn: "usage_event", columns: ["ts"])
                try? db.create(indexOn: "usage_event", columns: ["repo_path"])
            }),
            ("code_change", { db in
                try db.create(table: "code_change", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("commit_hash", .text).notNull().unique()
                    t.column("ts", .integer).notNull()
                    t.column("repo_path", .text).notNull()
                    t.column("added", .integer).defaults(to: 0)
                    t.column("deleted", .integer).defaults(to: 0)
                    t.column("is_merge", .boolean).defaults(to: false)
                }
                try? db.create(indexOn: "code_change", columns: ["ts"])
                try? db.create(indexOn: "code_change", columns: ["repo_path"])
            }),
            ("subscription_tool", { db in
                try db.create(table: "subscription_tool", ifNotExists: true) { t in
                    t.column("id", .text).primaryKey()
                    t.column("name", .text).notNull()
                    t.column("monthly_fee", .double).notNull()
                    t.column("currency", .text).defaults(to: "USD")
                }
            }),
            ("balance_snapshot", { db in
                try db.create(table: "balance_snapshot", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("ts", .integer).notNull()
                    t.column("provider_id", .text).notNull()
                    t.column("balance", .double).notNull()
                    t.column("currency", .text).defaults(to: "USD")
                    t.column("cost_source_id", .text)
                }
                try? db.create(indexOn: "balance_snapshot", columns: ["ts"])
                try? db.create(indexOn: "balance_snapshot", columns: ["provider_id"])
            }),
            ("logwatcher_position", { db in
                try db.create(table: "logwatcher_position", ifNotExists: true) { t in
                    t.column("file_path", .text).primaryKey()
                    t.column("byte_offset", .integer).notNull().defaults(to: 0)
                }
            }),
            ("gitmonitor_state", { db in
                try db.create(table: "gitmonitor_state", ifNotExists: true) { t in
                    t.column("repo_path", .text).primaryKey()
                    t.column("last_commit", .text)
                }
            }),
            ("cost_source", { db in
                try db.create(table: "cost_source", ifNotExists: true) { t in
                    t.column("id", .text).primaryKey()
                    t.column("label", .text).notNull()
                    t.column("kind", .text).notNull()
                    t.column("confidence", .text).notNull()
                    t.column("monthly_fee", .double)
                    t.column("usage_percent", .double)
                    t.column("usage_limit_status", .text)
                }
            }),
            ("quota_status", { db in
                // Subscription quota/limit state, independent of whether the
                // user configured a subscription tier. Written by UsageMonitor
                // from Claude status cache + Copilot API; read by Dashboard HUD.
                try db.create(table: "quota_status", ifNotExists: true) { t in
                    t.column("tool_id", .text).primaryKey()   // "claude-code" / "copilot"
                    t.column("utilization", .double).notNull() // 0-100
                    t.column("limit_status", .text)
                    t.column("reset_at", .double)             // Unix timestamp of next reset
                    t.column("window_seconds", .double)       // quota window length (for last-reset)
                    t.column("updated_at", .double)
                }
            }),
            ("dashboard_cache", { db in
                try db.create(table: "dashboard_cache", ifNotExists: true) { t in
                    t.column("time_range", .text).notNull()
                    t.column("json", .text).notNull()
                    t.column("updated_at", .datetime).notNull()
                    t.primaryKey(["time_range"])
                }
            }),
            ("session_info", { db in
                try db.create(table: "session_info", ifNotExists: true) { t in
                    t.column("source", .text).notNull()
                    t.column("session_id", .text).notNull()
                    t.column("title", .text)
                    t.column("repo", .text)
                    t.column("first_ts", .integer)
                    t.column("last_ts", .integer)
                    t.column("completed", .boolean)
                    t.column("window_tokens", .integer)
                    t.primaryKey(["source", "session_id"])
                }
                try? db.create(indexOn: "session_info", columns: ["source", "session_id"])
            })
        ]

    /// Add a column to an existing table if it doesn't already have it.
    private func addColumnIfMissing(_ table: String, _ column: String, _ type: String) {
        do {
            try dbQueue?.write { db in
                let exists = (try? db.columns(in: table).contains { $0.name == column }) ?? false
                if !exists {
                    try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
                    Logger.info("  + \(table).\(column) added")
                }
            }
        } catch {
            Logger.error("  ✗ addColumn \(table).\(column): \(error)")
        }
    }

    var writer: DatabaseWriter? { dbQueue }

    func write<T: Sendable>(_ updates: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let queue = dbQueue else { throw AppDBError.notReady }
        return try await queue.write(updates)
    }

    func read<T: Sendable>(_ value: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let queue = dbQueue else { throw AppDBError.notReady }
        return try await queue.read(value)
    }
}

enum AppDBError: Error {
    case notReady
}
