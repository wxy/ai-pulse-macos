import Foundation
import GRDB

final class AppDatabase: @unchecked Sendable {
    static let shared = AppDatabase()
    private(set) var databaseURL: URL?
    private var dbQueue: DatabaseQueue?

    /// Debug builds must not contend with an installed release for SQLite locks
    /// or accidentally mix test-generated usage with production history.
    static var databaseDirectoryName: String {
        #if DEBUG
        RuntimeQA.isEnabled ? "AIPulseRuntimeQA" : "AIPulseDebug"
        #else
        "AIPulse"
        #endif
    }

    /// Preserve the old raw table while replacing global hash uniqueness.
    /// Call inside a write transaction, after additive columns are installed.
    static func migrateRepositoryCodeIdentity(_ db: Database) throws {
        let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(code_change)")
        var hasGlobalHash = false
        for index in indexes where (index["unique"] as Int? ?? 0) == 1 {
            let name: String = index["name"]
            let escaped = name.replacingOccurrences(of: "'", with: "''")
            let columns = try Row.fetchAll(db, sql: "PRAGMA index_info('\(escaped)')")
                .compactMap { $0["name"] as String? }
            if columns == ["commit_hash"] { hasGlobalHash = true }
        }
        guard hasGlobalHash else { return }
        try db.execute(sql: """
            ALTER TABLE code_change RENAME TO code_change_legacy_raw;
            CREATE TABLE code_change (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                commit_hash TEXT NOT NULL, ts INTEGER NOT NULL, repo_path TEXT NOT NULL,
                added INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0, is_merge BOOLEAN DEFAULT 0,
                attributed_tool TEXT, attribution TEXT,
                UNIQUE(repo_path, commit_hash)
            );
            INSERT INTO code_change
              (id, commit_hash, ts, repo_path, added, deleted, is_merge, attributed_tool, attribution)
            SELECT id, commit_hash, ts, repo_path, added, deleted, is_merge, attributed_tool, attribution
            FROM code_change_legacy_raw;
            CREATE INDEX code_change_v2_ts ON code_change(ts);
            CREATE INDEX code_change_v2_repo ON code_change(repo_path);
            UPDATE git_commit_scan SET head_hash = NULL, status = 'partial';
            """)
    }

    func setup() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dbDir = appSupport.appendingPathComponent(Self.databaseDirectoryName)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("aipulse.db").path
        try setup(at: dbPath, defaults: .standard)
    }

    /// Run the production startup migration against an isolated database and
    /// preference domain without touching the user's active profile.
    func setup(at dbPath: String, defaults: UserDefaults) throws {
        // WAL: this app commits constantly (logwatcher cursors, usage batches,
        // dashboard cache rewrites). The default DELETE journal creates and
        // removes a rollback journal per transaction with an extra fsync;
        // WAL appends and checkpoints, and keeps crash recovery cheap.
        var configuration = Configuration()
        configuration.journalMode = .wal
        dbQueue = try DatabaseQueue(path: dbPath, configuration: configuration)
        databaseURL = URL(fileURLWithPath: dbPath)
        Logger.info("DB opened at \(dbPath)")

        try dbQueue?.write { try AppDatabase.createAllTables($0) }

        // Additive column migrations for existing installs
        // (create-ifNotExists won't add columns to tables that already exist).
        // Failures surface to the startup DB-error path: continuing with a
        // partial schema makes every aggregate query that references the
        // missing column throw for the whole session.
        try addColumnIfMissing("quota_status", "window_seconds", "REAL")
        try addColumnIfMissing("usage_event", "cache_creation_tokens", "INTEGER")
        try addColumnIfMissing("usage_event", "reported_output_tokens", "INTEGER")
        try addColumnIfMissing("usage_event", "reasoning_tokens", "INTEGER")
        // v2 WI-5: AI attribution on code changes — NULL means unattributed
        // (stays a对照-only row, never counted as consumption).
        try addColumnIfMissing("code_change", "attributed_tool", "TEXT")
        try addColumnIfMissing("code_change", "attribution", "TEXT")
        try dbQueue?.write { db in
            try Self.migrateRepositoryCodeIdentity(db)
            try Self.backfillKnownProviderAttributionIfNeeded(db, defaults: defaults)
            try Self.migrateLegacyQuotaStatus(db)
            try Self.normalizeCodeAttributionConfidence(db)
            _ = try LogCheckpointStore.prepareReliableReplay(in: db)
        }

        // The first DSH scan marked compressed journals complete before
        // multi-frame zstd decoding worked. Their usage lines are immutable,
        // so dropping only those parser positions is enough to replay them
        // safely while usage_event dedupe keys prevent duplicates.
        let dshReplayKey = "dsh_usage_shape_positions_replayed_v2"
        if !defaults.bool(forKey: dshReplayKey) {
            try dbQueue?.write { db in
                try Self.invalidateDeepSeekHarnessPositions(db)
            }
            defaults.set(true, forKey: dshReplayKey)
        }

        // Re-read immutable Claude logs to enrich previously omitted cache
        // creation metadata. Existing raw input and historical amounts stay intact.
        let claudeCreationReplayKey = "claude_cache_creation_metadata_replayed_v2"
        if !defaults.bool(forKey: claudeCreationReplayKey) {
            try dbQueue?.write { db in
                try Self.invalidateClaudeCacheCreationPositions(db)
            }
            defaults.set(true, forKey: claudeCreationReplayKey)
        }

        let dshCounterReplayKey = "dsh_disjoint_usage_metadata_replayed_v2"
        if !defaults.bool(forKey: dshCounterReplayKey) {
            try dbQueue?.write { db in
                try Self.invalidateDeepSeekHarnessPositions(db)
            }
            defaults.set(true, forKey: dshCounterReplayKey)
        }

        let codexOutputReplayKey = "codex_reported_output_metadata_replayed_v2"
        if !defaults.bool(forKey: codexOutputReplayKey) {
            try dbQueue?.write { db in
                try Self.invalidateCodexOutputPositions(db)
            }
            defaults.set(true, forKey: codexOutputReplayKey)
        }

        // Line counts recorded before the git_patch_line_stats argument-order
        // fix carried context lines in `added` and additions in `deleted`.
        // Drop the in-window derived rows and reset each scan cursor so the
        // next poll rebuilds them with correct stats — persistBatch's
        // INSERT OR IGNORE would otherwise keep the wrong rows forever.
        let gitLineStatsReplayKey = "git_line_stats_replayed_v1"
        if !defaults.bool(forKey: gitLineStatsReplayKey) {
            try dbQueue?.write { db in
                try Self.invalidateGitLineStats(db)
            }
            defaults.set(true, forKey: gitLineStatsReplayKey)
        }

        // Startup used to cache a snapshot at the 20-second mark while cold
        // history import could still be running. Rebuild those derived rows
        // once; usage and balance facts are never touched.
        let cacheRebuildKey = "dashboard_cache_rebuilt_after_startup_backfill_guard"
        if !defaults.bool(forKey: cacheRebuildKey) {
            try dbQueue?.write { db in
                try db.execute(sql: "DELETE FROM dashboard_cache")
            }
            defaults.set(true, forKey: cacheRebuildKey)
        }
        Logger.info("DB migration complete")
    }

    /// All table migrations, in dependency order. Exposed as a static so
    /// tests can run the same schema against an in-memory database.
    static func createAllTables(_ db: Database) throws {
        for (_, migration) in tables {
            try migration(db)
        }
    }

    /// Earlier Codex scans missed `session_meta.payload.model`, so valid GLM
    /// and DeepSeek rows could stay unattributed after the byte offset advanced.
    /// Provider attribution is factual; pricing/cost remains untouched.
    ///
    /// Guarded by a one-time defaults key: without it, any row whose model
    /// never matches the catalog re-triggers the full scan + rewrite + cache
    /// wipe on every launch.
    static func backfillKnownProviderAttributionIfNeeded(
        _ db: Database,
        defaults: UserDefaults,
        key: String = "known_provider_attribution_backfilled_v1"
    ) throws {
        guard !defaults.bool(forKey: key) else { return }
        try backfillKnownProviderAttribution(db)
        defaults.set(true, forKey: key)
    }

    static func backfillKnownProviderAttribution(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, model FROM usage_event
            WHERE model IS NOT NULL AND (provider_id IS NULL OR provider_id = 'unknown')
            """)
        var updates: [(id: Int64, providerId: String)] = []
        for row in rows {
            guard let id: Int64 = row["id"],
                  let model: String = row["model"],
                  let providerId = ModelCatalogManager.shared.providerId(for: model)
            else { continue }
            updates.append((id, providerId))
        }

        guard !updates.isEmpty else { return }
        for update in updates {
            try db.execute(sql: """
                UPDATE usage_event SET provider_id = ? WHERE id = ?
                """, arguments: [update.providerId, update.id])
        }
        try db.execute(sql: "DELETE FROM dashboard_cache")
        Logger.info("DB attributed \(updates.count) usage events to known providers")
    }

    /// Preserve the last legacy quota observation when upgrading to the
    /// multi-window schema. New observations use stable window ids (5h/7d/etc).
    static func migrateLegacyQuotaStatus(_ db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO quota_window_status
              (tool_id, window_id, utilization, limit_status, reset_at,
               window_seconds, updated_at)
            SELECT tool_id, 'legacy', utilization, limit_status, reset_at,
                   window_seconds, COALESCE(updated_at, 0)
            FROM quota_status
            """)
    }

    /// A commit trailer is a strong declaration signal, but it does not prove
    /// that every changed line was authored by AI. Preserve the attribution and
    /// normalize only its confidence label.
    static func normalizeCodeAttributionConfidence(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE code_change
            SET attribution = 'uncertain'
            WHERE attribution = 'exact'
            """)
    }

    static func invalidateCodexOutputPositions(
        _ db: Database,
        sessionDirectory: String = FileManager.default.realHomeDirectory
            .appendingPathComponent(".codex/sessions").path
    ) throws {
        let paths = try String.fetchAll(db, sql: "SELECT file_path FROM logwatcher_position")
        for path in paths where path.hasPrefix(sessionDirectory + "/")
            && URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-")
            && path.hasSuffix(".jsonl") {
            try db.execute(sql: "DELETE FROM logwatcher_position WHERE file_path = ?", arguments: [path])
        }
        try db.execute(sql: "DELETE FROM dashboard_cache")
    }

    static func invalidateClaudeCacheCreationPositions(
        _ db: Database,
        projectDirectory: String = FileManager.default.realHomeDirectory
            .appendingPathComponent(".claude/projects").path
    ) throws {
        let prefix = projectDirectory + "/"
        let paths = try String.fetchAll(db, sql: "SELECT file_path FROM logwatcher_position")
        for path in paths where path.hasPrefix(prefix) && path.hasSuffix(".jsonl") {
            try db.execute(sql: "DELETE FROM logwatcher_position WHERE file_path = ?", arguments: [path])
        }
        try db.execute(sql: "DELETE FROM dashboard_cache")
    }

    /// Clear parser positions for the current user's DSH journals and derived
    /// dashboard rows. Exposed for a regression test; callers decide when the
    /// one-time replay runs.
    static func invalidateDeepSeekHarnessPositions(
        _ db: Database,
        homeDirectory: String = FileManager.default.realHomeDirectory.path
    ) throws {
        try db.execute(sql: """
            DELETE FROM logwatcher_position
            WHERE file_path LIKE ?
            """, arguments: ["\(homeDirectory)/.dsh/sessions/%/session.jsonl.zstd"])
        try db.execute(sql: "DELETE FROM dashboard_cache")
    }

    /// Drop the code-change rows inside GitMonitor's coverage window and
    /// reset every scan cursor, so watches rebuild the window with corrected
    /// line statistics. Uses the same -29-day start-of-day boundary as
    /// GitMonitor.scanRecentCommits; rows older than the window sit outside
    /// every dashboard window and are left untouched.
    static func invalidateGitLineStats(
        _ db: Database,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        let coverageStart = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        let coverageSinceMs = Int(coverageStart.timeIntervalSince1970 * 1000)
        try db.execute(sql: "DELETE FROM code_change WHERE ts >= ?", arguments: [coverageSinceMs])
        try db.execute(sql: "UPDATE git_commit_scan SET head_hash = NULL, status = 'partial'")
        try db.execute(sql: "DELETE FROM dashboard_cache")
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
                    t.column("cache_creation_tokens", .integer)
                    t.column("reported_output_tokens", .integer)
                    t.column("reasoning_tokens", .integer)
                    t.column("cost_usd", .double)
                    t.column("repo_path", .text)
                    t.column("session_id", .text)
                    t.column("dedupe_key", .text).unique()
                    t.column("cost_source_id", .text)
                    t.column("cost_confidence", .text).defaults(to: "estimated")
                }
                try? db.create(indexOn: "usage_event", columns: ["ts"])
                try? db.create(indexOn: "usage_event", columns: ["repo_path"])
                try? db.create(indexOn: "usage_event", columns: ["source", "ts"])
                try? db.create(indexOn: "usage_event", columns: ["source", "session_id", "ts"])
            }),
            ("code_change", { db in
                try db.create(table: "code_change", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("commit_hash", .text).notNull()
                    t.column("ts", .integer).notNull()
                    t.column("repo_path", .text).notNull()
                    t.column("added", .integer).defaults(to: 0)
                    t.column("deleted", .integer).defaults(to: 0)
                    t.column("is_merge", .boolean).defaults(to: false)
                    // v2 WI-5 AI attribution (also added by migration for
                    // existing installs; NULL = unattributed →对照-only row)
                    t.column("attributed_tool", .text)
                    t.column("attribution", .text)
                    t.uniqueKey(["repo_path", "commit_hash"])
                }
                try? db.create(indexOn: "code_change", columns: ["ts"])
                try? db.create(indexOn: "code_change", columns: ["repo_path"])
            }),
            ("git_commit", { db in
                try db.create(table: "git_commit", ifNotExists: true) { t in
                    t.column("repo_path", .text).notNull()
                    t.column("commit_hash", .text).notNull()
                    t.column("ts", .integer).notNull()
                    t.column("parent_count", .integer).notNull()
                    t.column("author_email", .text).notNull()
                    // Recognized tool trailer is provenance, not proof of
                    // AI authorship or of the value of the resulting code.
                    t.column("attributed_tool", .text)
                    t.primaryKey(["repo_path", "commit_hash"])
                }
                try db.create(index: "git_commit_ts", on: "git_commit", columns: ["ts"], ifNotExists: true)
            }),
            ("git_commit_scan", { db in
                try db.create(table: "git_commit_scan", ifNotExists: true) { t in
                    t.column("repo_path", .text).primaryKey()
                    t.column("head_hash", .text)
                    t.column("updated_at", .integer).notNull()
                    t.column("coverage_since", .integer).notNull()
                    t.column("author_email", .text)
                    t.column("status", .text).notNull()
                }
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
                try db.create(index: "balance_snapshot_provider_ts_id", on: "balance_snapshot",
                              columns: ["provider_id", "ts", "id"], ifNotExists: true)
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
            ("quota_window_status", { db in
                try db.create(table: "quota_window_status", ifNotExists: true) { t in
                    t.column("tool_id", .text).notNull()
                    t.column("window_id", .text).notNull()
                    t.column("utilization", .double).notNull()
                    t.column("limit_status", .text)
                    t.column("reset_at", .double)
                    t.column("window_seconds", .double)
                    t.column("updated_at", .double).notNull()
                    t.primaryKey(["tool_id", "window_id"])
                }
                try? db.create(indexOn: "quota_window_status", columns: ["updated_at"])
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
    /// Throws so a failed migration surfaces through the startup DB-error
    /// path instead of leaving the app to run on a partial schema.
    private func addColumnIfMissing(_ table: String, _ column: String, _ type: String) throws {
        try dbQueue?.write { db in
            let exists = (try? db.columns(in: table).contains { $0.name == column }) ?? false
            if !exists {
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
                Logger.info("  + \(table).\(column) added")
            }
        }
    }

    var writer: DatabaseWriter? { dbQueue }

    /// Ingest worker only; keep checkpoint loading ordered before scanning.
    func readSynchronously<T>(_ value: (Database) throws -> T) throws -> T {
        guard let queue = dbQueue else { throw AppDBError.notReady }
        return try queue.read(value)
    }

    /// Ingest worker only: returning success must precede any cursor advance.
    func writeSynchronously<T>(_ updates: (Database) throws -> T) throws -> T {
        guard let queue = dbQueue else { throw AppDBError.notReady }
        return try queue.write(updates)
    }

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
