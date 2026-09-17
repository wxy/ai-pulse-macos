import GRDB

enum GitWatchStore {
    /// Synchronizes only the derived watch list. Commit/activity history and
    /// retained watch-row metadata are not rewritten or deleted.
    static func synchronize(in db: Database, repositories: Set<String>) throws {
        let stored = Set(try String.fetchAll(db, sql: "SELECT repo_path FROM gitmonitor_state"))
        for path in stored.subtracting(repositories) {
            try db.execute(sql: "DELETE FROM gitmonitor_state WHERE repo_path = ?", arguments: [path])
        }
        for path in repositories.subtracting(stored) {
            try db.execute(sql: "INSERT INTO gitmonitor_state (repo_path) VALUES (?)", arguments: [path])
        }
    }
}
