import XCTest
@testable import AIPulse

/// End-to-end coverage of the DeepSeek Harness scan loop over a synthetic
/// compressed journal — the file format, metadata threading, usage mapping,
/// completion detection and mtime fallback for time-less lines, none of which
/// the parser-only tests reach.
///
/// The vendored libzstd is decompress-only (the app never compresses), so the
/// fixture is a pre-built single-RAW-block zstd frame checked in under
/// Tests/Fixtures — any conformant decoder reads it.
final class DeepSeekHarnessScanTests: XCTestCase {
    private let fixtureLines: [String] = [
        #"{"type":"session","id":"sess-1","cwd":"/dev/repo"}"#,
        #"{"type":"session/title","data":{"title":"Refactor auth"}}"#,
        #"{"type":"request/header","data":{"header":{"config":{"model":"deepseek-chat"}}}}"#,
        #"{"type":"assistant/chunk","data":{"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":20,"reasoningTokens":10,"cacheWriteTokens":5}}},"time":1700000000000}"#,
        // No `time` field: the scan must fall back to the file's mtime.
        #"{"type":"assistant/chunk","data":{"chunk":{"type":"usage","usage":{"inputTokens":30,"outputTokens":20,"cacheReadTokens":0,"reasoningTokens":0,"cacheWriteTokens":0}}}}"#,
        #"{"type":"turn/end","data":{"reason":{"kind":"completed"}}}"#,
    ]

    private func journalFixture() throws -> (url: URL, lines: [String]) {
        let copied = FileManager.default.temporaryDirectory
            .appendingPathComponent("aipulse-dsh-synthetic-\(UUID().uuidString).zstd")
        try FileManager.default.copyItem(at: try Self.fixtureURL(), to: copied)
        return (copied, fixtureLines)
    }

    /// SwiftPM's resource nesting inside the test bundle differs across
    /// toolchains; direct lookups miss the Fixtures subdirectory, so walk it.
    private static func fixtureURL() throws -> URL {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: "dsh-synthetic-session",
                                withExtension: "zstd", subdirectory: "Fixtures") { return url }
        if let url = bundle.url(forResource: "dsh-synthetic-session", withExtension: "zstd") { return url }
        let enumerator = FileManager.default.enumerator(at: bundle.bundleURL,
                                                        includingPropertiesForKeys: nil)
        let matches = ((enumerator?.allObjects as? [URL]) ?? [])
            .filter { $0.lastPathComponent == "dsh-synthetic-session.zstd" }
        return try XCTUnwrap(matches.first, "fixture missing from the test bundle")
    }

    func testScanReplaysMetadataUsageCompletionAndMtimeFallback() throws {
        let (url, _) = try journalFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        var persistedBatches: [[UsageEvent]] = []
        let result = try LogWatcher.parseDeepSeekHarnessStream(at: url) { events in
            persistedBatches.append(events)
        }

        XCTAssertEqual(result.parsedCount, 2)
        XCTAssertEqual(persistedBatches.flatMap { $0 }.count, 2)
        XCTAssertEqual(result.sessionId, "sess-1")
        XCTAssertEqual(result.cwd, "/dev/repo")
        XCTAssertEqual(result.title, "Refactor auth")
        XCTAssertEqual(result.model, "deepseek-chat")
        XCTAssertTrue(result.completed)

        let events = persistedBatches.flatMap { $0 }
        XCTAssertEqual(events[0].ts, 1_700_000_000_000)
        XCTAssertEqual(events[0].model, "deepseek-chat")
        XCTAssertEqual(events[0].inTokens, 100, "v2 input excludes the cache slice")
        XCTAssertEqual(events[0].cacheTokens, 20)
        XCTAssertEqual(events[0].outTokens, 50, "reasoning is a detail of output, never added twice")
        XCTAssertEqual(events[0].reportedOutputTokens, 50)
        XCTAssertEqual(events[0].cacheCreationTokens, 5)
        XCTAssertEqual(events[0].repoPath, "/dev/repo")

        // The time-less line lands on the journal's mtime, not the wall clock
        // of the scan — within a generous minute of the stat we just took.
        let mtimeMs = LogWatcher.fileModificationMs(url)
        XCTAssertGreaterThan(events[1].ts, 0)
        XCTAssertLessThan(abs(events[1].ts - mtimeMs), 60_000)

        XCTAssertEqual(result.minTs, events[0].ts)
        XCTAssertEqual(result.maxTs, max(events[0].ts, events[1].ts))
        // byteCount accumulates the replayed (decompressed) journal bytes.
        let replayedBytes = fixtureLines.joined(separator: "\n").count + 1
        XCTAssertEqual(result.byteCount, replayedBytes)
    }

    func testScanResumeIsIdempotentThroughDedupeKeys() throws {
        let (url, _) = try journalFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try LogWatcher.parseDeepSeekHarnessStream(at: url) { _ in }
        let second = try LogWatcher.parseDeepSeekHarnessStream(at: url) { _ in }
        let keys = Set((first.events + second.events).map(\.dedupeKey))
        XCTAssertEqual(keys.count, first.events.count,
                       "replaying the same journal must not mint new identities")
    }
}
