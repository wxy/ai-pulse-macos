import Foundation
import GRDB

/// Loads the ChatGPT/Codex desktop app's own thread titles from
/// `~/.codex/state_5.sqlite` (threads table), so sessions show the name the
/// app gave them instead of a raw log line. Read-only, cached in memory.
enum CodexThreadTitles {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var cache: [String: String]?
    private static nonisolated(unsafe) var cachedPath: String?

    static func title(for sessionId: String) -> String? {
        loadIfNeeded()
        return cache?[sessionId]
    }

    static func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        let path = FileManager.default.realHomeDirectory
            .appendingPathComponent(".codex/state_5.sqlite").path
        guard cachedPath != path || cache == nil else { return }
        cache = readTitles(from: path)
        cachedPath = path
    }

    /// Read-only query of the threads table; returns threadId → title map.
    static func readTitles(from path: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: path, configuration: config)
            defer { try? queue.close() }
            return try queue.read { db in
                var map: [String: String] = [:]
                let rows = try Row.fetchAll(
                    db, sql: "SELECT id, title FROM threads WHERE title IS NOT NULL AND title != ''")
                for row in rows {
                    let id: String? = row["id"]
                    let title: String? = row["title"]
                    if let id, let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                        map[id] = title
                    }
                }
                return map
            }
        } catch {
            return [:]
        }
    }
}
