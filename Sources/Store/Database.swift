import Foundation
import GRDB

final class AppDatabase {
    static let shared = AppDatabase()
    private var dbQueue: DatabaseQueue?

    func setup() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbDir = appSupport.appendingPathComponent("AIPulse")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("aipulse.db").path
        dbQueue = try DatabaseQueue(path: dbPath)

        try dbQueue?.write { db in
            try db.create(table: "usage_event", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .integer).notNull()
                t.column("source", .text).notNull()
                t.column("provider_id", .text)
                t.column("model", .text)
                t.column("in_tokens", .integer).defaults(to: 0)
                t.column("out_tokens", .integer).defaults(to: 0)
                t.column("cache_tokens", .integer).defaults(to: 0)
                t.column("cost_usd", .double)
                t.column("repo_path", .text)
                t.column("session_id", .text)
                t.column("dedupe_key", .text).unique()
            }
            try db.create(indexOn: "usage_event", columns: ["ts"])
            try db.create(indexOn: "usage_event", columns: ["repo_path"])

            try db.create(table: "code_change", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("commit_hash", .text).notNull().unique()
                t.column("ts", .integer).notNull()
                t.column("repo_path", .text).notNull()
                t.column("added", .integer).defaults(to: 0)
                t.column("deleted", .integer).defaults(to: 0)
                t.column("is_merge", .boolean).defaults(to: false)
            }
            try db.create(indexOn: "code_change", columns: ["ts"])
            try db.create(indexOn: "code_change", columns: ["repo_path"])
        }
    }

    var writer: DatabaseWriter? { dbQueue }

    func write<T>(_ updates: @escaping (Database) throws -> T) async throws -> T {
        guard let queue = dbQueue else { throw AppDBError.notReady }
        return try await queue.write(updates)
    }

    func read<T>(_ value: @escaping (Database) throws -> T) async throws -> T {
        guard let queue = dbQueue else { throw AppDBError.notReady }
        return try await queue.read(value)
    }
}

enum AppDBError: Error {
    case notReady
}
