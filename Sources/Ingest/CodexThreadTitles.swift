import Foundation
import GRDB

/// Loads the ChatGPT/Codex desktop app's own thread titles from
/// `~/.codex/state_5.sqlite` (threads table), so sessions show the name the
/// app gave them instead of a raw log line. Read-only, cached in memory.
enum CodexThreadTitles {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var cache: [String: String]?
    private static nonisolated(unsafe) var cachedPath: String?
    private static nonisolated(unsafe) var cachedLoadFailed = false

    static func title(for sessionId: String) -> String? {
        // All access to the cache is under the lock: loadIfNeeded can run
        // from any queue, and an unsynchronized read of a mutating
        // dictionary reference is a data race.
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        return cache?[sessionId]
    }

    /// Callers must hold `lock`.
    private static func loadIfNeededLocked() {
        let path = FileManager.default.realHomeDirectory
            .appendingPathComponent(".codex/state_5.sqlite").path
        // A failed load (locked database) is retried on each query instead
        // of being cached as an empty map for the rest of the run.
        guard cachedPath != path || cache == nil || (cache?.isEmpty == true && cachedLoadFailed)
        else { return }
        if let titles = readTitles(from: path) {
            cache = titles
            cachedLoadFailed = false
        } else {
            cache = [:]
            cachedLoadFailed = true
        }
        cachedPath = path
    }

    /// Read-only query of the threads table; returns threadId → title map.
    /// Returns nil when the database exists but could not be opened or read
    /// (retry later); a missing file or empty table yields an empty map.
    static func readTitles(from path: String) -> [String: String]? {
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
            return nil
        }
    }
}
