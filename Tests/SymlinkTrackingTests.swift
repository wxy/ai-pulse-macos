import Foundation
import GRDB
import XCTest
@testable import AIPulse

/// Filesystem → discovery/authorization → parsing → durable usage/cursors.
/// All inputs, Git repositories and SQLite files live in a disposable directory.
final class SymlinkTrackingTests: XCTestCase {
    private func directory(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func link(_ source: URL, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testLinkedDevelopmentTreeDiscoveryAuthorizationAndRevocation() async throws {
        let base = try directory(FileManager.default.temporaryDirectory, "aipulse-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let realDevelop = try directory(base, "real-development")
        let develop = base.appendingPathComponent("develop")
        try link(develop, to: realDevelop)
        XCTAssertTrue(BookmarkManager.pathIsCovered(develop.path, by: realDevelop.path))
        XCTAssertTrue(BookmarkManager.pathIsCovered(realDevelop.path, by: develop.path))
        XCTAssertFalse(BookmarkManager.pathIsCovered(realDevelop.path + "-sibling", by: develop.path))
        let external = try directory(base, "external")
        let repo = try directory(external, "group/project")
        let sibling = try directory(external, "unselected")
        try git(["init", "--quiet", repo.path])
        try git(["init", "--quiet", sibling.path])
        try FileManager.default.createSymbolicLink(
            atPath: develop.appendingPathComponent("group").path, withDestinationPath: "../external/group")
        try link(develop.appendingPathComponent("alias"), to: repo)
        try link(develop.appendingPathComponent("loop"), to: develop)
        try link(develop.appendingPathComponent("broken"), to: external.appendingPathComponent("missing"))
        let nested = try directory(repo, "Sources/Feature")
        XCTAssertFalse(BookmarkManager.pathIsCovered(develop.appendingPathComponent("group/project").path, by: develop.path),
                       "An external target still needs its own OS grant")
        XCTAssertTrue(BookmarkManager.pathIsCovered(develop.appendingPathComponent("group/project").path, by: external.path))

        let domain = "SymlinkTrackingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let cache = RepoScanCache(store: defaults)
        await cache.scan(dir: develop.path)
        XCTAssertEqual(cache.cachedScan(for: develop.path)?.repos.map(\.path), [RepositoryScope.canonicalPath(repo.path)])
        await cache.scan(dir: realDevelop.path)
        XCTAssertEqual(cache.totalRepos(in: [develop.path, realDevelop.path]), 1)
        XCTAssertEqual(RepositoryScope.authorizedGitRoot(for: nested.path, roots: [develop.path]),
                       RepositoryScope.canonicalPath(repo.path))
        XCTAssertNil(RepositoryScope.authorizedGitRoot(for: sibling.path, roots: [develop.path]))
        var lookup = RepositoryScope.AuthorizedRootLookup(roots: [develop.path])
        XCTAssertEqual(lookup.root(for: nested.path), RepositoryScope.canonicalPath(repo.path))

        try FileManager.default.removeItem(at: develop.appendingPathComponent("group"))
        try FileManager.default.removeItem(at: develop.appendingPathComponent("alias"))
        XCTAssertFalse(RepositoryScope.isInsideConfiguredRoots(repo.path, roots: [develop.path]))
        var nextRead = RepositoryScope.AuthorizedRootLookup(roots: [develop.path])
        XCTAssertNil(nextRead.root(for: nested.path))
    }

    func testTraversalPreservesSkipsDepthAndLinkedRoot() throws {
        let base = try directory(FileManager.default.temporaryDirectory, "aipulse-depth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let realDevelop = try directory(base, "real-development")
        let develop = base.appendingPathComponent("develop")
        try link(develop, to: realDevelop)
        let external = try directory(base, "external")
        _ = try directory(external, "project/.git")
        try link(develop.appendingPathComponent("node_modules"), to: external)
        try link(develop.appendingPathComponent(".hidden"), to: external)
        let deep = try directory(develop, "a/b/c/d")
        try link(deep.appendingPathComponent("too-deep"), to: external)
        var found: [URL] = []
        GitRepoScanner.enumerate(in: develop) { found.append($0) }
        XCTAssertTrue(found.isEmpty)
        let rootLink = base.appendingPathComponent("selected")
        try link(rootLink, to: external)
        GitRepoScanner.enumerate(in: rootLink) { found.append($0) }
        XCTAssertEqual(found.map(\.path), [RepositoryScope.canonicalPath(external.appendingPathComponent("project").path)])
    }

    func testLinkedLogsImportAppendRestartRetargetAndBrokenLinkRecovery() async throws {
        let base = try directory(FileManager.default.temporaryDirectory, "aipulse-ingest-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let realHome = try directory(base, "real-home")
        let home = base.appendingPathComponent("home")
        try link(home, to: realHome)
        let codex = try directory(home, ".codex")
        let external = try directory(base, "external")
        let sessions = try directory(external, "sessions")
        let day = try directory(external, "day")
        try link(codex.appendingPathComponent("sessions"), to: sessions)
        try link(sessions.appendingPathComponent("2026"), to: day)
        try link(sessions.appendingPathComponent("duplicate"), to: day)
        try link(day.appendingPathComponent("cycle"), to: sessions)
        try link(sessions.appendingPathComponent("broken"), to: external.appendingPathComponent("missing"))
        let file = day.appendingPathComponent("rollout-synthetic.jsonl")
        let meta = #"{"type":"session_meta","payload":{"session_id":"link-session","model":"gpt-5-codex"}}"# + "\n"
        func event(_ id: Int) -> String {
            #"{"timestamp":"2026-10-22T00:00:0\#(id)Z","type":"token_count","payload":{"last_token_usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n"
        }
        try (meta + event(1)).write(to: file, atomically: true, encoding: .utf8)
        // A file alias must not get a second checkpoint or use the link's size.
        let fileAlias = sessions.appendingPathComponent("rollout-alias.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
        try link(fileAlias, to: file)
        XCTAssertEqual(LogWatcher.fileModificationMs(fileAlias), LogWatcher.fileModificationMs(file),
                       "Fallback timestamps belong to the target, never the link")
        let domain = "SymlinkIngestTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let database = AppDatabase()
        try database.setup(at: base.appendingPathComponent("qa.sqlite").path, defaults: defaults)
        let watcher = LogWatcher(homeDirectory: home, database: database, repositoryRoots: [])
        await watcher.scanAndWait()
        func count() throws -> Int {
            try database.readSynchronously { try Int.fetchOne($0, sql: "SELECT count(*) FROM usage_event")! }
        }
        XCTAssertEqual(try count(), 1)
        // The same target can appear under a different link order next pass.
        await watcher.scanAndWait()
        XCTAssertEqual(try count(), 1)
        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd()
        let pending = Data(event(2).utf8)
        try append.write(contentsOf: pending.dropLast())
        await watcher.scanAndWait()
        XCTAssertEqual(try count(), 1, "Incomplete lines stay pending")
        try append.write(contentsOf: Data("\n".utf8))
        try append.close()
        await watcher.scanAndWait()
        XCTAssertEqual(try count(), 2)
        let restarted = LogWatcher(homeDirectory: home, database: database, repositoryRoots: [])
        await restarted.scanAndWait()
        XCTAssertEqual(try count(), 2)
        let checkpoints = try database.readSynchronously { try LogCheckpointStore.load(in: $0) }
        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertEqual(checkpoints[RepositoryScope.canonicalPath(file.path)], UInt64(try Data(contentsOf: file).count))

        let replacement = try directory(external, "replacement")
        try event(3).write(to: replacement.appendingPathComponent("rollout-new.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: codex.appendingPathComponent("sessions"))
        try link(codex.appendingPathComponent("sessions"), to: replacement)
        await restarted.scanAndWait()
        XCTAssertEqual(try count(), 3)
        try FileManager.default.removeItem(at: codex.appendingPathComponent("sessions"))
        try link(codex.appendingPathComponent("sessions"), to: external.appendingPathComponent("recovered"))
        await restarted.scanAndWait()
        XCTAssertEqual(try count(), 3)
        let recovered = try directory(external, "recovered")
        try event(4).write(to: recovered.appendingPathComponent("rollout-recovered.jsonl"), atomically: true, encoding: .utf8)
        await restarted.scanAndWait()
        XCTAssertEqual(try count(), 4)
        let qwenProject = try directory(home, ".qwen/projects/project")
        let qwenData = try directory(external, "qwen-data")
        try link(qwenProject.appendingPathComponent("chats"), to: qwenData)
        // An irrelevant alias visited first must not hide the valid chats path.
        try link(qwenProject.appendingPathComponent("other"), to: qwenData)
        let geminiProject = try directory(home, ".gemini/tmp/project")
        let geminiData = try directory(external, "gemini-data")
        try link(geminiProject.appendingPathComponent("chats"), to: geminiData)
        let header = #"{"sessionId":"linked-chat","projectHash":"synthetic"}"# + "\n"
        let usage = #"{"id":"linked-message","timestamp":"2026-10-22T00:00:05Z","type":"gemini","model":"qwen3-coder","tokens":{"input":10,"output":5,"total":15}}"# + "\n"
        let qwenFile = qwenData.appendingPathComponent("payload.txt")
        try (header + usage).write(to: qwenFile, atomically: true, encoding: .utf8)
        try link(qwenData.appendingPathComponent("session.jsonl"), to: qwenFile)
        try (header + usage).write(to: geminiData.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        await restarted.scanAndWait()
        XCTAssertEqual(try count(), 6, "Linked chats retain their logical source layout")
        await restarted.scanAndWait()
        XCTAssertEqual(try count(), 6)
        let movedHome = try directory(base, "moved-home")
        let movedSessions = try directory(movedHome, ".codex/sessions")
        try event(5).write(to: movedSessions.appendingPathComponent("rollout-moved.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: home)
        try link(home, to: movedHome)
        await restarted.scanAndWait()
        XCTAssertEqual(try count(), 7, "Retargeting the home link uses its new tree")
        watcher.stop()
        restarted.stop()
        await watcher.waitForPendingScan()
        await restarted.waitForPendingScan()
    }
}
