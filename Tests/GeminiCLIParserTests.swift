import XCTest
import GRDB
@testable import AIPulse

/// The Gemini CLI adapter: format verified against upstream
/// `google-gemini/gemini-cli` chatRecordingService (see GeminiCLIParser's doc
/// comment). Parsing delegates to QwenCodeParser under the gemini-cli source
/// label; these tests pin that delegation and the qwen defaults.
final class GeminiCLIParserTests: XCTestCase {
    func testRepairOfCheckpointedLegacyRowsChangesOnlyMissingGeminiSessionId() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aipulse-gemini-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let header = "{\"sessionId\":\"recovered-session\",\"projectHash\":\"opaque\"}\n"
        let line = "{\"id\":\"old\",\"type\":\"gemini\",\"model\":\"gemini-2.5-pro\",\"timestamp\":\"2026-09-27T10:00:01.000Z\",\"tokens\":{\"input\":10,\"cached\":2,\"output\":3,\"total\":13}}\n"
        let bytes = Data((header + line).utf8)
        try bytes.write(to: file)
        let old = try XCTUnwrap(GeminiCLIParser.parse(line: line.trimmingCharacters(in: .newlines), cwd: nil))
        XCTAssertNil(old.sessionId)
        let unrelated = UsageEvent(ts: old.ts, source: "qwen-code", model: "qwen3-coder",
                                   inTokens: 7, outTokens: 1, cacheTokens: 0,
                                   repoPath: nil, sessionId: nil, dedupeKey: "qwen|unrelated")
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            _ = try LogWatcher.persistObservedEvents(in: db,
                rows: [(old, "google"), (unrelated, "qwen")], nowMs: 1_800_000_000_000)
            try LogCheckpointStore.save([file.path: UInt64(bytes.count)], in: db)
        }

        func repair(_ url: URL) throws -> Int? {
            // Reload DB-backed repair state on every call to model a new process.
            let state = try queue.write { try LogWatcher.loadGeminiRepairState(in: $0) }
            guard let fingerprint = LogWatcher.GeminiRepairFingerprint.of(url) else { return nil }
            guard state[url.path]?.fingerprint != fingerprint else { return 0 }
            let result = try LogWatcher.repairGeminiSessionIds(at: url, previous: state[url.path]) { id, keys in
                try queue.write { try LogWatcher.updateMissingGeminiSessionIds(in: $0, sessionId: id, keys: keys) }
            }
            if let result {
                try queue.write { try LogWatcher.saveGeminiRepairState(in: $0, path: url.path, state: result.state) }
            }
            return result?.repaired
        }

        // Simulate a restart after the old build saved EOF: normal incremental
        // parsing has no unread bytes, so only the repair can attach the ID.
        XCTAssertEqual(try repair(file), 1)
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT session_id, in_tokens, out_tokens, cache_tokens FROM usage_event WHERE dedupe_key = ?", arguments: [old.dedupeKey])
            XCTAssertEqual(row?["session_id"], "recovered-session")
            XCTAssertEqual(row?["in_tokens"], 10)
            XCTAssertEqual(row?["out_tokens"], 3)
            XCTAssertEqual(row?["cache_tokens"], 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event"), 2)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT session_id FROM usage_event WHERE source = 'qwen-code'"))
            XCTAssertEqual(try LogCheckpointStore.load(in: db)[file.path], UInt64(bytes.count))
        }
        XCTAssertEqual(try repair(file), 0, "persisted fingerprint skips unchanged file after restart")
        let malformedLine = line.replacingOccurrences(of: "\"old\"", with: "\"unattributed\"")
        let malformedEvent = try XCTUnwrap(GeminiCLIParser.parse(line: malformedLine.trimmingCharacters(in: .newlines), cwd: nil))
        try queue.write { db in
            _ = try LogWatcher.persistObservedEvents(in: db,
                rows: [(malformedEvent, "google")], nowMs: 1_800_000_000_000)
        }
        try Data(("{\"sessionId\":\"wrong\"}\n" + malformedLine).utf8).write(to: file)
        XCTAssertNil(try repair(file),
                       "missing projectHash must not reattribute rows")
        XCTAssertNil(try queue.read { try LogWatcher.loadGeminiRepairState(in: $0)[file.path]?.fingerprint == LogWatcher.GeminiRepairFingerprint.of(file) ? "marked" : nil },
                     "invalid header must never be marked complete")
        XCTAssertNil(try queue.read { db in
            try String.fetchOne(db, sql: "SELECT session_id FROM usage_event WHERE dedupe_key = ?", arguments: [malformedEvent.dedupeKey])
        })
        try Data(("{\"sessionId\":\"recovered-session\",\"projectHash\":\"opaque\"}\n" + malformedLine).utf8).write(to: file)
        XCTAssertEqual(try repair(file), 1, "rewritten file is retryable")

        let second = directory.appendingPathComponent("new-session.jsonl")
        let newLine = line.replacingOccurrences(of: "\"old\"", with: "\"new-file\"")
        let newEvent = try XCTUnwrap(GeminiCLIParser.parse(line: newLine.trimmingCharacters(in: .newlines), cwd: nil))
        try queue.write { db in
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(newEvent, "google")], nowMs: 1_800_000_000_000)
        }
        try Data((header + newLine).utf8).write(to: second)
        XCTAssertEqual(try repair(second), 1, "new file is not skipped by prior state")
        try FileManager.default.removeItem(at: second)
        XCTAssertNil(try repair(second), "temporary file I/O failure cannot be marked complete")
    }

    func testOrphanNullRowDoesNotForceFullReplayOnEveryAppend() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aipulse-gemini-append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let header = "{\"sessionId\":\"active\",\"projectHash\":\"opaque\"}\n"
        func line(_ id: Int) -> String {
            "{\"id\":\"\(id)\",\"type\":\"gemini\",\"model\":\"gemini-2.5-pro\",\"timestamp\":\"2026-09-27T10:00:01.000Z\",\"tokens\":{\"input\":1,\"total\":2}}\n"
        }
        var revision = 0
        func write(_ text: String) throws {
            revision += 1
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000_000 + revision))], ofItemAtPath: file.path)
        }
        var contents = header + line(0)
        try write(contents)
        let queue = try DatabaseQueue()
        try queue.write { db in
            try AppDatabase.createAllTables(db)
            let orphan = UsageEvent(ts: 1, source: "gemini-cli", model: "gemini-2.5-pro",
                                    inTokens: 1, outTokens: 1, cacheTokens: 0, repoPath: nil,
                                    sessionId: nil, dedupeKey: "gemini-cli|deleted-file")
            _ = try LogWatcher.persistObservedEvents(in: db, rows: [(orphan, "google")], nowMs: 2)
        }
        func repair() throws -> (Int, UInt64)? {
            let saved = try queue.write { try LogWatcher.loadGeminiRepairState(in: $0)[file.path] }
            let result = try LogWatcher.repairGeminiSessionIds(at: file, previous: saved) { id, keys in
                try queue.write { try LogWatcher.updateMissingGeminiSessionIds(in: $0, sessionId: id, keys: keys) }
            }
            if let result {
                try queue.write { try LogWatcher.saveGeminiRepairState(in: $0, path: file.path, state: result.state) }
            }
            return result.map { ($0.repaired, $0.startedAt) }
        }
        XCTAssertEqual(try repair()?.1, 0)
        for id in 1...3 {
            let oldSize = UInt64(contents.utf8.count)
            contents += line(id)
            try write(contents)
            XCTAssertEqual(try repair()?.1, oldSize, "append \(id) must resume at the saved byte cursor")
            XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT session_id FROM usage_event WHERE dedupe_key = 'gemini-cli|deleted-file'") }, nil)
        }
        // A same-size rewrite and a shorter file both require a full replay.
        contents = contents.replacingOccurrences(of: "\"id\":\"3\"", with: "\"id\":\"4\"")
        try write(contents)
        XCTAssertEqual(try repair()?.1, 0)
        contents = header + line(0)
        try write(contents)
        XCTAssertEqual(try repair()?.1, 0)
        contents = contents.replacingOccurrences(of: "\"active\"", with: "\"otherx\"")
        try write(contents)
        XCTAssertEqual(try repair()?.1, 0, "header identity change must not reuse old cursor")
        let rotated = directory.appendingPathComponent("replacement.jsonl")
        try Data((contents + line(5)).utf8).write(to: rotated)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: rotated, to: file)
        XCTAssertEqual(try repair()?.1, 0, "rotated file must not reuse the old inode cursor")
    }

    func testSessionHeaderAttributionSurvivesIncrementalResumeAndPersistsDistinctSubagent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aipulse-gemini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = directory.appendingPathComponent("chats")
        let childDir = chats.appendingPathComponent("parent-id")
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        let parent = chats.appendingPathComponent("session-parent.jsonl")
        let child = childDir.appendingPathComponent("child.jsonl")
        let header = "{\"sessionId\":\"parent-id\",\"projectHash\":\"opaque\",\"startTime\":\"2026-09-27T10:00:00.000Z\"}\n"
        let childHeader = "{\"sessionId\":\"child-id\",\"projectHash\":\"opaque\"}\n"
        func message(_ id: String, tokens: Bool = true) -> String {
            "{\"id\":\"\(id)\",\"type\":\"gemini\",\"model\":\"gemini-2.5-pro\",\"timestamp\":\"2026-09-27T10:00:01.000Z\"\(tokens ? ",\"tokens\":{\"input\":10,\"cached\":2,\"output\":3,\"total\":13}" : "")}\n"
        }
        try Data((header + message("one") + message("no-usage", tokens: false)).utf8).write(to: parent)
        try Data((childHeader + message("child")).utf8).write(to: child)
        let queue = try DatabaseQueue()
        try queue.write { try AppDatabase.createAllTables($0) }

        func scan(_ url: URL, from start: UInt64) throws -> UInt64 {
            let id = GeminiCLIParser.sessionId(at: url)
            let size = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? UInt64)
            return try JSONLCheckpoint.read(at: url, from: start, fileSize: size,
                parse: { GeminiCLIParser.parse(line: $0, cwd: nil, sessionId: id) },
                persist: { events in
                    try queue.write { db in
                        _ = try LogWatcher.persistObservedEvents(in: db,
                            rows: events.map { ($0, "google") }, nowMs: 1_800_000_000_000)
                    }
                })
        }

        var parentCursor = try scan(parent, from: 0)
        _ = try scan(child, from: 0)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT session_id FROM usage_event WHERE dedupe_key = ?", arguments: [GeminiCLIParser.parse(line: message("one").trimmingCharacters(in: .newlines), cwd: nil)?.dedupeKey ?? ""]) }, "parent-id")
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_event WHERE session_id = 'child-id'") }, 1)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_event") }, 2)

        try Data((header + message("one") + message("no-usage", tokens: false) + message("two")).utf8).write(to: parent)
        parentCursor = try scan(parent, from: parentCursor) // Reconstruct header from file after a fresh scan state.
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_event WHERE session_id = 'parent-id'") }, 2)
        _ = try scan(parent, from: 0) // Replay is deduplicated.
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_event") }, 3)
        XCTAssertEqual(parentCursor, try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: parent.path))[.size] as? UInt64))
    }

    func testSessionHeaderValidationRejectsMalformedAndMessageLikeRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aipulse-gemini-header-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        for header in ["not-json", "{\"sessionId\":\"\",\"projectHash\":\"hash\"}",
                       "{\"sessionId\":\"fake\",\"type\":\"gemini\",\"projectHash\":\"hash\"}",
                       "{\"sessionId\":\"missing-hash\"}"] {
            try Data((header + "\n").utf8).write(to: file)
            XCTAssertNil(GeminiCLIParser.sessionId(at: file))
        }
    }
    func testGeminiMessageWithFullTokenSummary() {
        let line = """
        {"id":"m1","timestamp":"2026-09-27T10:00:00.000Z","type":"gemini","model":"gemini-2.5-pro","content":"ok","tokens":{"input":100,"output":150,"cached":40,"thoughts":30,"tool":10,"total":250}}
        """
        let event = GeminiCLIParser.parse(line: line, cwd: nil)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.source, "gemini-cli")
        XCTAssertEqual(event?.model, "gemini-2.5-pro")
        XCTAssertEqual(event?.inTokens, 100)
        XCTAssertEqual(event?.cacheTokens, 40)
        XCTAssertEqual(event?.outTokens, 150, "output is total minus input; thoughts/tool never add twice")
        XCTAssertTrue(event?.dedupeKey.hasPrefix("gemini-cli|") == true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(event?.ts, Int(formatter.date(from: "2026-09-27T10:00:00.000Z")!.timeIntervalSince1970 * 1000))
    }

    func testNonGeminiMessagesProduceNoEvent() {
        // Metadata header, user message, tool-call record shapes: no usage.
        let header = """
        {"sessionId":"s1","projectHash":"abc","startTime":"2026-09-27T10:00:00.000Z","lastUpdated":"2026-09-27T10:05:00.000Z"}
        """
        let user = """
        {"id":"m0","timestamp":"2026-09-27T10:00:01.000Z","type":"user","content":"hi"}
        """
        let rewind = """
        {"$rewindTo":"m0"}
        """
        XCTAssertNil(GeminiCLIParser.parse(line: header, cwd: nil))
        XCTAssertNil(GeminiCLIParser.parse(line: user, cwd: nil))
        XCTAssertNil(GeminiCLIParser.parse(line: rewind, cwd: nil))
    }

    func testGarbageTimestampFallsBackToFileMtime() {
        let line = """
        {"id":"m2","timestamp":"bogus","type":"gemini","model":"gemini-2.5-flash","content":"x","tokens":{"input":5,"output":6,"cached":0,"total":11}}
        """
        let event = GeminiCLIParser.parse(line: line, cwd: nil, fallbackTimestampMs: 1_790_000_000_000)
        XCTAssertEqual(event?.ts, 1_790_000_000_000)
    }

    func testSessionFileClassification() {
        XCTAssertTrue(GeminiCLIParser.isSessionFile(URL(fileURLWithPath: "/h/.gemini/tmp/abc123/chats/session-2026-09-27T10-00-abcd1234.jsonl")))
        XCTAssertTrue(GeminiCLIParser.isSessionFile(URL(fileURLWithPath: "/h/.gemini/tmp/abc123/chats/parent-uuid/session-xyz.jsonl")),
                      "subagent sessions nest one level below chats/")
        XCTAssertFalse(GeminiCLIParser.isSessionFile(URL(fileURLWithPath: "/h/.gemini/tmp/abc123/checkpoint.json")))
        XCTAssertFalse(GeminiCLIParser.isSessionFile(URL(fileURLWithPath: "/h/.gemini/tmp/abc123/chats")))
    }

    func testQwenDefaultsStayStableAcrossTheRefactor() {
        let line = """
        {"id":"m1","timestamp":"2026-09-27T10:00:00.000Z","type":"gemini","model":"qwen3-coder","content":"ok","tokens":{"input":10,"output":5,"cached":0,"thoughts":0,"tool":0,"total":15}}
        """
        let event = QwenCodeParser.parse(line: line, cwd: nil)
        XCTAssertEqual(event?.source, "qwen-code")
        XCTAssertTrue(event?.dedupeKey.hasPrefix("qwen|") == true,
                      "existing installs must keep their dedupe keys after the source-parameter refactor")
    }
}
