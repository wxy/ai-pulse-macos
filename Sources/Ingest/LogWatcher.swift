import Foundation
import GRDB

/// Watches Claude Code log directories for new session files and incrementally parses them
final class LogWatcher {
    static let shared = LogWatcher()
    private var source: DispatchSourceFileSystemObject?

    func start() {
        let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: claudeProjects.path) else {
            print("Claude Code projects directory not found at \(claudeProjects.path)")
            return
        }

        // Scan existing session files
        scanExisting(at: claudeProjects)

        // Watch for new files
        let fd = open(claudeProjects.path, O_EVTONLY)
        guard fd >= 0 else { return }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        source?.setEventHandler { [weak self] in
            self?.scanExisting(at: claudeProjects)
        }
        source?.setCancelHandler { close(fd) }
        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func scanExisting(at dir: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl" else { continue }
            parseFile(at: file)
        }
    }

    private func parseFile(at url: URL) {
        // Extract cwd from the parent directory name (encoded path)
        let parentDir = url.deletingLastPathComponent().lastPathComponent
        let cwd = decodeCWD(from: parentDir)

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines)
        let sessionId = url.deletingPathExtension().lastPathComponent

        for line in lines {
            guard !line.isEmpty else { continue }
            guard let event = ClaudeCodeParser.parse(line: line, cwd: cwd, sessionId: sessionId) else { continue }
            insertEvent(event)
        }
    }

    private func insertEvent(_ event: UsageEvent) {
        Task {
            do {
                let providerId = PricingManager.shared.providerId(for: event.model) ?? "unknown"
                let cost = PricingManager.shared.costUSD(
                    model: event.model,
                    inTokens: event.inTokens,
                    outTokens: event.outTokens,
                    cacheTokens: event.cacheTokens
                )
                try await AppDatabase.shared.write { db in
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO usage_event
                          (ts, source, provider_id, model, in_tokens, out_tokens, cache_tokens, cost_usd, repo_path, session_id, dedupe_key)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            event.ts,
                            event.source,
                            providerId,
                            event.model,
                            event.inTokens,
                            event.outTokens,
                            event.cacheTokens,
                            cost,
                            event.repoPath,
                            event.sessionId,
                            event.dedupeKey,
                        ]
                    )
                }
            } catch {
                print("Failed to insert usage event: \(error)")
            }
        }
    }

    /// Decode Claude Code's cwd directory name.
    /// Claude Code encodes absolute paths by replacing '/' with '-', e.g.:
    /// /Users/foo/bar → -Users-foo-bar
    private func decodeCWD(from dirName: String) -> String? {
        // Claude Code encodes '/' as '-'. Try the naive replacement first,
        // then verify the result exists on disk.
        let path = "/" + dirName.replacingOccurrences(of: "-", with: "/")
        // Strip leading double-slash if present
        let clean = path.replacingOccurrences(of: "//", with: "/")
        if FileManager.default.fileExists(atPath: clean) { return clean }
        // Fallback: return the best-guess path even if it doesn't exist
        // (repo may have been deleted but logs remain)
        return clean
    }
}
