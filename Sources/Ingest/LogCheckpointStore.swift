import GRDB

enum LogCheckpointStore {
    enum Failure: Error { case invalidOffset }

    /// Atomic, once per local database. Derived cursors only; raw facts survive.
    static func prepareReliableReplay(in db: Database) throws -> Bool {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS log_ingest_state (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
        let key = "ordered_complete_line_checkpoints"
        guard try Int.fetchOne(db, sql: "SELECT value FROM log_ingest_state WHERE key = ?", arguments: [key]) != 1 else { return false }
        try db.execute(sql: "UPDATE logwatcher_position SET byte_offset = 0")
        try db.execute(sql: "INSERT OR REPLACE INTO log_ingest_state VALUES (?, 1)", arguments: [key])
        return true
    }

    static func load(in db: Database) throws -> [String: UInt64] {
        var positions: [String: UInt64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT file_path, byte_offset FROM logwatcher_position") {
            let path: String = row["file_path"]
            let offset: Int64 = row["byte_offset"]
            guard offset >= 0 else { throw Failure.invalidOffset }
            positions[path] = UInt64(offset)
        }
        return positions
    }

    static func save(_ positions: [String: UInt64], in db: Database) throws {
        for (path, offset) in positions {
            guard let stored = Int64(exactly: offset) else { throw Failure.invalidOffset }
            try db.execute(sql: """
                INSERT OR REPLACE INTO logwatcher_position (file_path, byte_offset) VALUES (?, ?)
                """, arguments: [path, stored])
        }
    }
}
