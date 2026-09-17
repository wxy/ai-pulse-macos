import Foundation
import GRDB
import Darwin
import XCTest
@testable import AIPulse

final class RealProfileMigrationTests: XCTestCase {
    func testActualDeepSeekJournalUsesBoundedBatches() throws {
        guard let path = ProcessInfo.processInfo.environment["AIPULSE_QA_DSH_LOG"] else {
            throw XCTSkip("Requires a local compressed journal via AIPULSE_QA_DSH_LOG")
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("aipulse-dsh-\(UUID().uuidString).zstd")
        try FileManager.default.copyItem(atPath: path, toPath: copy.path)
        defer { try? FileManager.default.removeItem(at: copy) }
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        var persisted = 0
        let result = try LogWatcher.parseDeepSeekHarnessStream(at: copy) { events in
            XCTAssertLessThanOrEqual(events.count, 512)
            persisted += events.count
        }
        XCTAssertGreaterThan(persisted, 0)
        XCTAssertEqual(persisted, result.parsedCount)
        XCTAssertTrue(result.events.isEmpty)
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        print("DSH_REAL_REPLAY events=\(persisted) peak_rss_before_bytes=\(before.ru_maxrss) peak_rss_after_bytes=\(after.ru_maxrss)")
    }

    func testActualCodexJournalReplayIsDeduplicatedAndSilent() throws {
        guard let path = ProcessInfo.processInfo.environment["AIPULSE_QA_CODEX_LOG"] else {
            throw XCTSkip("Requires a local journal via AIPULSE_QA_CODEX_LOG")
        }
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("aipulse-journal-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(atPath: path, toPath: snapshot.path)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as? UInt64)
        let queue = try DatabaseQueue()
        try queue.write { try AppDatabase.createAllTables($0) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var firstCount = 0
        var firstPosition: UInt64 = 0
        var originalContext: [String: (repo: String?, model: String?, session: String?)] = [:]
        for pass in 0..<2 {
            var cwd: String?
            var model: String?
            var session: String?
            var parsed = 0
            let position = try JSONLCheckpoint.read(at: snapshot, from: 0, fileSize: size, parse: { line in
                if let value = CodexParser.cwd(fromLine: line) { cwd = value }
                if let value = CodexParser.sessionMetaModel(fromLine: line) { model = value }
                if let value = CodexParser.model(fromLine: line) { model = value }
                if let value = CodexParser.sessionId(fromLine: line) { session = value }
                let event = CodexParser.parse(line: line, cwd: cwd, model: model, sessionId: session)
                if let event {
                    parsed += 1
                    if pass == 0 { originalContext[event.dedupeKey] = (event.repoPath, event.model, event.sessionId) }
                }
                return event
            }, persist: { events in
                try queue.write { db in
                    let feedback = try LogWatcher.persistObservedEvents(in: db,
                        rows: events.map { ($0, "openai") }, nowMs: now, liveSinceMs: now + 1)
                    XCTAssertEqual(feedback, 0, "History replay must not trigger consumption feedback")
                }
            })
            XCTAssertGreaterThan(parsed, 0)
            if pass == 0 { firstCount = parsed; firstPosition = position }
            else { XCTAssertEqual(parsed, firstCount); XCTAssertEqual(position, firstPosition) }
        }
        // Restart in the middle of the real journal, reconstructing context with
        // the same helper used by the production incremental scanner.
        var cwd: String?
        var model: String?
        var session: String?
        var resumedEvents = 0
        let parse: (String) -> UsageEvent? = { line in
            if let value = CodexParser.cwd(fromLine: line) { cwd = value }
            if let value = CodexParser.sessionMetaModel(fromLine: line) { model = value }
            if let value = CodexParser.model(fromLine: line) { model = value }
            if let value = CodexParser.sessionId(fromLine: line) { session = value }
            return CodexParser.parse(line: line, cwd: cwd, model: model, sessionId: session)
        }
        let midpoint = try JSONLCheckpoint.read(at: snapshot, from: 0, fileSize: size / 2,
            parse: parse, persist: { _ in })
        let context = try XCTUnwrap(LogWatcher.codexResumeMetadata(at: snapshot, lastPosition: midpoint))
        cwd = context.cwd
        model = context.model
        session = context.sessionId
        let resumedPosition = try JSONLCheckpoint.read(at: snapshot, from: midpoint, fileSize: size,
            parse: parse, persist: { events in
                resumedEvents += events.count
                for event in events {
                    let expected = try XCTUnwrap(originalContext[event.dedupeKey])
                    XCTAssertEqual(event.repoPath, expected.repo)
                    XCTAssertEqual(event.model, expected.model)
                    XCTAssertEqual(event.sessionId, expected.session)
                }
                try queue.write { db in
                    XCTAssertEqual(try LogWatcher.persistObservedEvents(in: db,
                        rows: events.map { ($0, "openai") }, nowMs: now, liveSinceMs: now + 1), 0)
                }
            })
        XCTAssertGreaterThan(resumedEvents, 0)
        XCTAssertEqual(resumedPosition, firstPosition)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_event"), firstCount)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_event WHERE reported_output_tokens IS NULL OR session_id IS NULL OR cost_usd IS NOT NULL"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(\(TokenAccounting.observedTotalSQL)) FROM usage_event"),
                           try Int.fetchOne(db, sql: "SELECT SUM(in_tokens+reported_output_tokens) FROM usage_event"))
        }
    }

    /// Explicit local opt-in only: private history is never a repository fixture.
    func testProductionStartupPreservesIsolatedRealHistory() throws {
        guard let baseline = ProcessInfo.processInfo.environment["AIPULSE_QA_BASELINE"] else {
            throw XCTSkip("Requires a local SQLite backup via AIPULSE_QA_BASELINE")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aipulse-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("aipulse.db")
        try FileManager.default.copyItem(atPath: baseline, toPath: copy.path)
        let suite = "xingyu.wang.aipulse.migrationqa.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = AppDatabase()
        try database.setup(at: copy.path, defaults: defaults)
        try database.readSynchronously { db in
            try db.execute(sql: "ATTACH DATABASE ? AS baseline", arguments: [baseline])
            try verifyPreservedHistory(db)
            let columns = try db.columns(in: "usage_event").map(\.name)
            for column in ["cache_creation_tokens", "reported_output_tokens", "reasoning_tokens"] {
                XCTAssertTrue(columns.contains(column))
            }
            XCTAssertTrue(try db.tableExists("git_commit"))
            XCTAssertTrue(try db.tableExists("git_commit_scan"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_event WHERE \(TokenAccounting.missingComponentsSQL)"),
                           try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_event WHERE source IN ('claude-code','deepseek-harness','codex','opencode')"))
        }
        // A second startup must preserve the same raw facts and not duplicate rows.
        try database.setup(at: copy.path, defaults: defaults)
        try database.readSynchronously { db in
            try db.execute(sql: "ATTACH DATABASE ? AS baseline", arguments: [baseline])
            try verifyPreservedHistory(db)
        }
    }

    private func verifyPreservedHistory(_ db: Database) throws {
        XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check(1)"), "ok")
        let projections = [
            "usage_event": "id,ts,source,model,in_tokens,out_tokens,cache_tokens,cost_usd,repo_path,session_id,dedupe_key,cost_source_id,cost_confidence",
            "code_change": "id,commit_hash,ts,repo_path,added,deleted,is_merge",
            "balance_snapshot": "*",
            "quota_status": "tool_id,utilization,limit_status,reset_at,updated_at"
        ]
        for (table, projection) in projections {
            for (left, right) in [("main", "baseline"), ("baseline", "main")] {
                let changed = try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT \(projection) FROM \(left).\(table) EXCEPT SELECT \(projection) FROM \(right).\(table))")
                XCTAssertEqual(changed, 0, "Raw history changed in \(table)")
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM main.\(table)"),
                           try Int.fetchOne(db, sql: "SELECT count(*) FROM baseline.\(table)"))
        }
    }
}
